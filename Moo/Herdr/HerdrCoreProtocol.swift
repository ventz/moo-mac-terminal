//
//  HerdrCoreProtocol.swift
//  Moo
//
//  herdr-core's API as Moo uses it. herdr-core (`hc`, 0.1 and later) is the
//  daemon behind the Herdr app: it runs every terminal and agent and keeps
//  them alive when the window closes. It speaks JSON-RPC 2.0, one message
//  per line, on a socket in its state folder
//  (~/.local/state/herdr-core/<session>/<session>.sock), and describes
//  itself with `hc schema`. Shapes here were captured from herdr-core
//  0.1.19, protocol generation 1; unknown fields are ignored.
//
//  It is a different API from herdr 0.9's (HerdrProtocol.swift), which Moo
//  still speaks to herdr clients running in its own tabs.
//
//  Moo only ever subscribes. The same socket can start programs, type into
//  terminals and edit files, so requests are built from `HerdrCoreMethod`
//  alone: a method that is not in that enum cannot be sent.
//

import Darwin
import Foundation

/// Every herdr-core method Moo may call: one, and it only reads.
/// Pinned by HerdrCoreProtocolTests.onlyTheSubscriptionExists.
nonisolated enum HerdrCoreMethod: String, CaseIterable, Sendable {
    case subscribe = "events.subscribe"
}

/// One herdr-core terminal whose program reports a status (OSC 7501): an
/// agent, as the panel lists it.
nonisolated struct HerdrCoreTerminal: Equatable, Sendable {
    /// "t7": the terminal's address on its core, for `hc attach`.
    var address: String
    /// What the program calls itself ("claude-code"), or what runs in it.
    var agent: String
    var status: HerdrAgentStatus
    /// permission, question or auth, when a blocked program said which.
    var blockedKind: String?
    /// The program's own message with its status, if any.
    var message: String?
    /// Where the Herdr app shows it ("api / 1"): the `where` label, or the
    /// folder it runs in.
    var location: String
    var title: String
    /// What the session is about, for the line under the agent's name:
    /// the terminal's name when it has one (`hc run --name`), else the
    /// title the program set, unless that title says nothing.
    var summary: String?
}

nonisolated enum HerdrCoreEvent: Equatable, Sendable {
    /// A terminal appeared, or (restarted) came back.
    case upserted(seq: UInt64, raw: HerdrCoreRaw)
    case status(seq: UInt64, address: String, status: [String: String]?)
    case labels(seq: UInt64, address: String, labels: [String: String])
    case title(seq: UInt64, address: String, title: String)
    case foreground(seq: UInt64, address: String, name: String?, cwd: String?)
    /// Finished, lost or removed: no longer a live agent.
    case gone(seq: UInt64, address: String)
    case other(seq: UInt64)

    var seq: UInt64 {
        switch self {
        case .upserted(let seq, _), .status(let seq, _, _), .labels(let seq, _, _),
             .title(let seq, _, _), .foreground(let seq, _, _, _), .gone(let seq, _), .other(let seq):
            return seq
        }
    }
}

/// The facts Moo keeps about any live terminal, agent or not: a terminal can
/// start reporting a status at any time, and needs its labels and folder
/// to be listed then.
nonisolated struct HerdrCoreRaw: Equatable, Sendable {
    var address: String
    var status: [String: String]?
    var labels: [String: String]
    var title: String
    /// The name it was given (`hc run --name`), if any.
    var name: String?
    /// What runs in it: argv[0]'s name ("claude"), not the process title,
    /// which a program can set to anything (Claude Code's is its version).
    var foregroundName: String?
    var cwd: String

    /// The agent this terminal is, or nil while its program reports no
    /// status.
    var agent: HerdrCoreTerminal? {
        guard let status, let state = status["state"] else { return nil }
        let app = status["app"].flatMap { $0.isEmpty ? nil : $0 }
        let message = status["msg"].flatMap { $0.isEmpty ? nil : $0 }
        return HerdrCoreTerminal(
            address: address,
            agent: app ?? foregroundName ?? "agent",
            status: HerdrAgentStatus(raw: state),
            blockedKind: status["kind"].flatMap { $0.isEmpty ? nil : $0 },
            message: message,
            location: HerdrCoreProtocol.location(labels: labels, cwd: cwd),
            title: title,
            summary: HerdrCoreProtocol.summary(name: name, title: title, app: app, program: foregroundName)
        )
    }
}

nonisolated enum HerdrCoreMessage: Equatable, Sendable {
    /// The reply to events.subscribe: every matching terminal, and the
    /// sequence number events continue from.
    case snapshot(seq: UInt64, terminals: [HerdrCoreRaw])
    case event(HerdrCoreEvent)
    /// The subscriber fell behind: start over.
    case missed
    case heartbeat
    case error(kind: String, message: String)
    case other
}

nonisolated enum HerdrCoreProtocol {
    /// The most terminals Moo tracks on one core.
    static let terminalLimit = 512
    /// Addresses are "t7", or "machine/t7" for a terminal on another machine.
    static let addressLimit = 128

    static func subscribe(id: Int) -> HerdrRequest {
        HerdrProtocol.coreRequest(id: id, .subscribe)
    }

    static func parse(_ line: Data) -> HerdrCoreMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            let data = error["data"] as? [String: Any]
            return .error(
                kind: data?["kind"] as? String ?? "",
                message: error["message"] as? String ?? ""
            )
        }
        if let result = object["result"] as? [String: Any] {
            // Only events.subscribe is ever sent; a reply without terminals
            // is not one Moo understands.
            guard let terminals = result["terminals"] as? [[String: Any]] else {
                return .error(kind: "unexpected_reply", message: "herdr-core answered in a form Moo does not know.")
            }
            return .snapshot(
                seq: uint(result["seq"]) ?? 0,
                terminals: terminals.prefix(terminalLimit).compactMap(parseTerminal)
            )
        }
        switch object["method"] as? String {
        case "event":
            guard let params = object["params"] as? [String: Any] else { return .other }
            return event(params).map(HerdrCoreMessage.event) ?? .other
        case "missed":
            return .missed
        case "heartbeat":
            return .heartbeat
        default:
            return .other
        }
    }

    static func parseTerminal(_ object: [String: Any]) -> HerdrCoreRaw? {
        guard let address = object["address"] as? String, isValidAddress(address),
              object["state"] as? String ?? "live" == "live" else { return nil }
        let foreground = object["foreground"] as? [String: Any]
        return HerdrCoreRaw(
            address: address,
            status: strings(object["status"]),
            labels: strings(object["labels"]) ?? [:],
            title: object["title"] as? String ?? "",
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            foregroundName: programName(foreground),
            cwd: foreground?["cwd"] as? String ?? object["cwd"] as? String ?? ""
        )
    }

    /// One `event` notification:
    /// {"data": {...}, "seq": 609, "terminal": "t5", "type": "status"}.
    static func event(_ params: [String: Any]) -> HerdrCoreEvent? {
        guard let seq = uint(params["seq"]) else { return nil }
        let data = params["data"] as? [String: Any] ?? [:]
        guard let address = params["terminal"] as? String, isValidAddress(address) else {
            // Document events name no terminal.
            return .other(seq: seq)
        }
        switch params["type"] as? String {
        case "created", "restarted":
            guard let raw = parseTerminal(data) else { return .other(seq: seq) }
            return .upserted(seq: seq, raw: raw)
        case "status":
            return .status(seq: seq, address: address, status: strings(data["status"]))
        case "labels":
            return .labels(seq: seq, address: address, labels: strings(data["labels"]) ?? [:])
        case "title":
            guard let title = data["title"] as? String else { return .other(seq: seq) }
            return .title(seq: seq, address: address, title: title)
        case "foreground":
            return .foreground(seq: seq, address: address, name: programName(data), cwd: data["cwd"] as? String)
        case "finished", "lost", "removed":
            return .gone(seq: seq, address: address)
        default:
            return .other(seq: seq)
        }
    }

    /// The Herdr app labels each terminal `where: "<space> / <tab>"`; the
    /// space is what the panel groups by. Terminals started some other way
    /// are grouped by their folder.
    static func location(labels: [String: String], cwd: String) -> String {
        if let place = labels["where"], !place.isEmpty {
            let space = place.components(separatedBy: " / ").first ?? place
            if !space.isEmpty { return space }
        }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? "herdr" : folder
    }

    /// The line under an agent's name. Claude Code, for one, titles its
    /// terminal with a summary of the session ("Fix the login redirect"),
    /// as the Herdr app shows it. A title that only names the program, or
    /// is a path or a shell prompt ("user@host:~"), says nothing and is
    /// left out. Leading spinner and status glyphs are dropped, so a title
    /// animating while the agent works reads, and redraws, as one.
    static func summary(name: String?, title: String, app: String?, program: String?) -> String? {
        if let name, !name.isEmpty { return name }
        let text = String(title.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered == app?.lowercased() || lowered == program?.lowercased() { return nil }
        if text.hasPrefix("~") || text.hasPrefix("/") || text.contains("@") { return nil }
        if text.count >= 3, text.dropFirst().hasPrefix(":\\") { return nil }
        return text
    }

    /// argv[0]'s last path component, else the OS's name for the process.
    static func programName(_ foreground: [String: Any]?) -> String? {
        guard let foreground else { return nil }
        if let first = (foreground["argv"] as? [String])?.first {
            let name = (first as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return foreground["name"] as? String
    }

    static func isValidAddress(_ address: String) -> Bool {
        !address.isEmpty && address.utf8.count <= addressLimit
    }

    /// Only "t7" or "machine/t7" with a plain machine name: an address
    /// becomes part of a typed `hc attach` command.
    static func isAttachableAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "/", omittingEmptySubsequences: false)
        guard let terminal = parts.last, parts.count <= 2,
              terminal.count >= 2, terminal.first == "t",
              terminal.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        if parts.count == 2 {
            return HerdrDiscovery.isValidSessionName(String(parts[0]))
        }
        return true
    }

    /// A string-valued object, such as a status record or labels. Values
    /// that are not strings (progress, a nested record) are dropped.
    private static func strings(_ value: Any?) -> [String: String]? {
        guard let object = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object.prefix(64) {
            if let string = value as? String { result[key] = string }
        }
        return result
    }

    private static func uint(_ value: Any?) -> UInt64? {
        (value as? NSNumber).map(\.uint64Value)
    }
}

/// A herdr-core session Moo can talk to, named by its API socket.
nonisolated struct HerdrCoreEndpoint: Hashable, Sendable {
    var socketPath: String
    /// nil for the default session
    var sessionName: String?

    /// What opens one of its terminals in a Moo tab:
    /// `HC_SESSION=default hc attach t7`, with `--observe` to watch without
    /// typing or resizing it. The session is always named, so an HC_SESSION
    /// exported in the user's shell cannot point the click at another
    /// session's t7.
    func attachCommand(address: String, observe: Bool) -> String? {
        let session = sessionName ?? "default"
        guard HerdrCoreProtocol.isAttachableAddress(address),
              HerdrDiscovery.isValidSessionName(session) else { return nil }
        return "HC_SESSION=\(session) hc attach " + (observe ? "--observe " : "") + address
    }
}

nonisolated enum HerdrCoreDiscovery {
    /// Every herdr-core session with a socket in a state folder:
    /// `<state>/herdr-core/<name>/<name>.sock`, where <state> is
    /// ~/.local/state and, when Moo's own environment sets one,
    /// $XDG_STATE_HOME. (A Moo opened from the Dock does not see what a
    /// shell's rc file exports.) Only finds sockets; whether one may be used
    /// is HerdrDiscovery.trust's call.
    static func endpoints(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [HerdrCoreEndpoint] {
        var stateHomes: [String] = []
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") { stateHomes.append(xdg) }
        if home.hasPrefix("/") { stateHomes.append((home as NSString).appendingPathComponent(".local/state")) }
        var endpoints: [HerdrCoreEndpoint] = []
        var seen: Set<String> = []
        for stateHome in stateHomes {
            let root = (stateHome as NSString).appendingPathComponent("herdr-core")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names.sorted() where HerdrDiscovery.isValidSessionName(name) {
                let path = ((root as NSString).appendingPathComponent(name) as NSString)
                    .appendingPathComponent("\(name).sock")
                var info = stat()
                guard endpoints.count < 32, !seen.contains(path),
                      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { continue }
                seen.insert(path)
                endpoints.append(HerdrCoreEndpoint(socketPath: path, sessionName: name == "default" ? nil : name))
            }
        }
        return endpoints
    }
}
