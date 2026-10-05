//
//  HerdrProtocol.swift
//  Moo
//
//  herdr's socket API as Moo uses it: newline-delimited JSON, one request
//  per line, responses carrying the request's id, and pushed events of the
//  form {"event": name, "data": {...}}. Shapes were captured from herdr
//  0.9.3; unknown fields are ignored, as herdr's protocol notes ask.
//
//  Moo only ever reads herdr. The same socket can type into panes and
//  prompt agents, so requests are built from `HerdrMethod` alone: a method
//  that is not in that enum cannot be sent.
//

import Foundation

/// Every method Moo may call. Reads, subscriptions and focus only; nothing
/// that sends input, runs commands or closes anything.
/// Pinned by HerdrProtocolTests.onlyReadAndFocusMethodsExist.
nonisolated enum HerdrMethod: String, CaseIterable, Sendable {
    case ping = "ping"
    case snapshot = "session.snapshot"
    case subscribe = "events.subscribe"
    case paneFocus = "pane.focus"
    case agentFocus = "agent.focus"
}

/// A request line, as only `HerdrProtocol` can build it: the one thing a
/// HerdrConnection will send. Keeps "read-only" structural rather than a
/// convention.
nonisolated struct HerdrRequest: Sendable {
    let data: Data
    fileprivate init(_ data: Data) { self.data = data }
}

nonisolated enum HerdrAgentStatus: String, Sendable {
    case working
    case blocked
    case done
    case idle
    case unknown

    init(raw: String?) {
        self = raw.flatMap(HerdrAgentStatus.init(rawValue:)) ?? .unknown
    }

    /// Ready for input: herdr reports a finished turn as done until a herdr
    /// client has shown it, then idle.
    var isAtRest: Bool { self == .idle || self == .done }
}

/// One herdr pane as Moo tracks it.
nonisolated struct HerdrPane: Equatable, Sendable {
    var paneID: String
    var workspaceID: String
    var agent: String?
    var status: HerdrAgentStatus
}

nonisolated struct HerdrSnapshot: Equatable, Sendable {
    var version: String?
    var panes: [HerdrPane]
    /// Workspace id → label
    var workspaceLabels: [String: String]
    var focusedPaneID: String?
}

nonisolated enum HerdrEvent: Equatable, Sendable {
    case paneCreated(HerdrPane)
    case paneClosed(paneID: String)
    case paneFocused(paneID: String)
    /// An agent appeared in a pane, or (released) left it.
    case agentDetected(paneID: String, agent: String?, released: Bool)
    case statusChanged(paneID: String, agent: String?, status: HerdrAgentStatus)
    /// A workspace was created, renamed or closed: labels need a new snapshot.
    case workspacesChanged
    case other(String)
}

nonisolated enum HerdrMessage: Equatable, Sendable {
    case response(id: String, type: String?)
    case snapshot(id: String, HerdrSnapshot)
    case error(id: String, code: String, message: String)
    case event(HerdrEvent)
}

nonisolated enum HerdrProtocol {
    /// The longest line Moo reads. A snapshot of a large session is tens of
    /// kilobytes; anything near this is not herdr.
    static let lineLimit = 1 << 20

    /// The lowest herdr Moo talks to: endpoint generation 1, with
    /// `session.snapshot`.
    static let minimumVersion = (major: 0, minor: 9)

    /// Ids herdr gives panes and workspaces ("w1:p2"). Anything longer is
    /// not herdr, and is dropped rather than shown or sent back.
    static let idLimit = 128
    /// The most panes Moo tracks in one session.
    static let paneLimit = 512

    static func request(id: String, _ method: HerdrMethod, params: [String: String] = [:]) -> HerdrRequest {
        line(["id": id, "method": method.rawValue, "params": params])
    }

    static func subscribe(id: String, to subscriptions: [[String: String]]) -> HerdrRequest {
        line(["id": id, "method": HerdrMethod.subscribe.rawValue, "params": ["subscriptions": subscriptions]])
    }

    private static func line(_ object: [String: Any]) -> HerdrRequest {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return HerdrRequest(data)
    }

    /// The lifecycle subscription every session gets: panes coming and
    /// going, agents appearing, focus, and workspace labels.
    static let lifecycleSubscriptions: [[String: String]] = [
        ["type": "pane.created"],
        ["type": "pane.closed"],
        ["type": "pane.focused"],
        ["type": "pane.agent_detected"],
        ["type": "workspace.created"],
        ["type": "workspace.renamed"],
        ["type": "workspace.closed"],
    ]

    static func statusSubscription(paneID: String) -> [[String: String]] {
        [["type": "pane.agent_status_changed", "pane_id": paneID]]
    }

    // MARK: Parsing

    static func parse(_ line: Data) -> HerdrMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        if let name = object["event"] as? String {
            return .event(event(named: name, data: object["data"] as? [String: Any] ?? [:]))
        }
        let id = object["id"] as? String ?? ""
        if let error = object["error"] as? [String: Any] {
            return .error(
                id: id,
                code: error["code"] as? String ?? "",
                message: error["message"] as? String ?? ""
            )
        }
        guard let result = object["result"] as? [String: Any] else { return nil }
        let type = result["type"] as? String
        if type == "session_snapshot", let snapshot = result["snapshot"] as? [String: Any] {
            return .snapshot(id: id, parseSnapshot(snapshot))
        }
        return .response(id: id, type: type)
    }

    static func parseSnapshot(_ object: [String: Any]) -> HerdrSnapshot {
        var agents: [String: (name: String, status: HerdrAgentStatus)] = [:]
        for agent in object["agents"] as? [[String: Any]] ?? [] {
            guard let paneID = agent["pane_id"] as? String, let name = agent["agent"] as? String else { continue }
            agents[paneID] = (name, HerdrAgentStatus(raw: agent["agent_status"] as? String))
        }
        var panes: [HerdrPane] = []
        for pane in (object["panes"] as? [[String: Any]] ?? []).prefix(paneLimit) {
            guard var parsed = parsePane(pane) else { continue }
            if let agent = agents[parsed.paneID] {
                parsed.agent = parsed.agent ?? agent.name
                if parsed.status == .unknown { parsed.status = agent.status }
            }
            panes.append(parsed)
        }
        var labels: [String: String] = [:]
        for workspace in (object["workspaces"] as? [[String: Any]] ?? []).prefix(paneLimit) {
            guard let id = workspace["workspace_id"] as? String, isValidID(id) else { continue }
            labels[id] = workspace["label"] as? String ?? ""
        }
        return HerdrSnapshot(
            version: object["version"] as? String,
            panes: panes,
            workspaceLabels: labels,
            focusedPaneID: object["focused_pane_id"] as? String
        )
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= idLimit
    }

    static func parsePane(_ object: [String: Any]) -> HerdrPane? {
        guard let paneID = object["pane_id"] as? String, isValidID(paneID) else { return nil }
        let workspaceID = object["workspace_id"] as? String ?? ""
        guard workspaceID.utf8.count <= idLimit else { return nil }
        return HerdrPane(
            paneID: paneID,
            workspaceID: workspaceID,
            agent: object["agent"] as? String,
            status: HerdrAgentStatus(raw: object["agent_status"] as? String)
        )
    }

    /// herdr names some events with dots ("pane.agent_status_changed") and
    /// others with underscores ("pane_created"); both spellings are accepted.
    static func event(named name: String, data: [String: Any]) -> HerdrEvent {
        let paneID = (data["pane_id"] as? String).flatMap { isValidID($0) ? $0 : nil }
        switch name.replacingOccurrences(of: ".", with: "_") {
        case "pane_created":
            guard let pane = (data["pane"] as? [String: Any]).flatMap(parsePane) else { return .other(name) }
            return .paneCreated(pane)
        case "pane_closed":
            guard let paneID else { return .other(name) }
            return .paneClosed(paneID: paneID)
        case "pane_focused":
            guard let paneID = paneID ?? ((data["pane"] as? [String: Any]).flatMap(parsePane))?.paneID else {
                return .other(name)
            }
            return .paneFocused(paneID: paneID)
        case "pane_agent_detected":
            guard let paneID else { return .other(name) }
            return .agentDetected(
                paneID: paneID,
                agent: data["agent"] as? String,
                released: data["released"] as? Bool ?? false
            )
        case "pane_agent_status_changed":
            guard let paneID else { return .other(name) }
            return .statusChanged(
                paneID: paneID,
                agent: data["agent"] as? String,
                status: HerdrAgentStatus(raw: data["agent_status"] as? String)
            )
        case "workspace_created", "workspace_renamed", "workspace_closed":
            return .workspacesChanged
        default:
            return .other(name)
        }
    }

    /// "herdr 0.9.3" → (0, 9, 3)
    static func version(fromVersionOutput output: String) -> (major: Int, minor: Int, patch: Int)? {
        for word in output.split(whereSeparator: \.isWhitespace) {
            let parts = word.split(separator: ".").map { Int($0) }
            guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { continue }
            return (parts[0]!, parts[1]!, parts.count > 2 ? parts[2]! : 0)
        }
        return nil
    }

    static func isSupported(_ version: (major: Int, minor: Int, patch: Int)) -> Bool {
        (version.major, version.minor) >= (minimumVersion.major, minimumVersion.minor)
    }
}
