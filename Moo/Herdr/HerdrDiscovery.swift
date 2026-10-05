//
//  HerdrDiscovery.swift
//  Moo
//
//  Finding herdr from Moo's side: which panes run a herdr client, which
//  herdr session (and so which socket) each one is attached to, and whether
//  that socket can be trusted.
//

import Darwin
import Foundation

/// A herdr session Moo can talk to, named by its API socket.
nonisolated struct HerdrEndpoint: Hashable, Sendable {
    var socketPath: String
    /// nil for the default session
    var sessionName: String?
    /// Named by HERDR_SOCKET_PATH. A shell in a new tab would not resolve
    /// to the same server, so no reattach is offered for it.
    var isSocketOverride = false

    /// What reattaches a client to this session, when one can.
    var attachCommand: String? {
        if isSocketOverride { return nil }
        return sessionName.map { "herdr session attach \($0)" } ?? "herdr"
    }
}

nonisolated enum HerdrClientKind: Equatable, Sendable {
    /// A full herdr client on this Mac.
    case local(HerdrEndpoint)
    /// `herdr --remote <host>`: the server and its socket are on that host.
    case remote(host: String)
}

nonisolated enum HerdrDiscovery {
    /// What a herdr process is, from its arguments and environment. Nil for
    /// one-shot commands (`herdr pane list`) and anything that is not a full
    /// client. Mirrors herdr 0.9's own resolution: an explicit session
    /// (`--session`, `session attach`) beats HERDR_SOCKET_PATH, which beats
    /// HERDR_SESSION, which beats the default session.
    static func client(
        arguments: [String],
        environment: [String: String],
        home: String
    ) -> HerdrClientKind? {
        var explicitSession: String?
        var remoteHost: String?
        var positionals: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func value(for flag: String) -> String? {
                if argument == flag, index + 1 < arguments.count {
                    index += 1
                    return arguments[index]
                }
                if argument.hasPrefix(flag + "=") {
                    return String(argument.dropFirst(flag.count + 1))
                }
                return nil
            }
            if let session = value(for: "--session") {
                explicitSession = session
            } else if let host = value(for: "--remote") {
                remoteHost = host
            } else if argument.hasPrefix("-") {
                // Other flags (--handoff, -v) do not change which session.
            } else {
                positionals.append(argument)
            }
            index += 1
        }

        if positionals.count == 3, positionals[0] == "session", positionals[1] == "attach" {
            explicitSession = positionals[2]
        } else if !positionals.isEmpty {
            return nil
        }

        if let remoteHost {
            return .remote(host: remoteHost)
        }

        let configDirectory = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { ($0 as NSString).appendingPathComponent("herdr") }
            ?? ((environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home) as NSString)
                .appendingPathComponent(".config/herdr")

        func endpoint(session: String?) -> HerdrEndpoint? {
            guard let session, session != "default" else {
                return HerdrEndpoint(
                    socketPath: (configDirectory as NSString).appendingPathComponent("herdr.sock"),
                    sessionName: nil
                )
            }
            guard isValidSessionName(session) else { return nil }
            let path = ((configDirectory as NSString).appendingPathComponent("sessions") as NSString)
                .appendingPathComponent(session)
            return HerdrEndpoint(
                socketPath: (path as NSString).appendingPathComponent("herdr.sock"),
                sessionName: session
            )
        }

        if let explicitSession {
            return endpoint(session: explicitSession).map(HerdrClientKind.local)
        }
        if let override = environment["HERDR_SOCKET_PATH"], !override.isEmpty {
            // A relative path would resolve against Moo's directory, not the
            // client's.
            guard override.hasPrefix("/") else { return nil }
            return .local(HerdrEndpoint(socketPath: override, sessionName: nil, isSocketOverride: true))
        }
        return endpoint(session: environment["HERDR_SESSION"]).map(HerdrClientKind.local)
    }

    /// A session name becomes a path component and part of a typed
    /// `herdr session attach` command, so it may not climb out of the
    /// sessions directory or start like a flag.
    static func isValidSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name != ".", name != ".." else { return false }
        func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
        guard let first = name.unicodeScalars.first, isWordCharacter(first) else { return false }
        return name.unicodeScalars.allSatisfy { isWordCharacter($0) || $0 == "-" || $0 == "." }
    }

    // MARK: Processes

    /// argv and environment from KERN_PROCARGS2: argc, the executable path,
    /// NUL padding, argv, then the environment, each NUL-terminated.
    /// Only `keeping` environment variables are decoded: the rest of
    /// another process's environment (tokens included) never becomes a
    /// string in Moo.
    static func parseProcessArguments(
        _ buffer: [UInt8],
        keeping keys: Set<String>
    ) -> (arguments: [String], environment: [String: String])? {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0, argc < 4_096 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let string = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        var arguments: [String] = []
        while arguments.count < argc, let argument = nextString() {
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        let wanted = keys.map { (Array($0.utf8) + [UInt8(ascii: "=")], $0) }
        while index < size, buffer[index] != 0 {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let entry = buffer[start..<index]
            index += 1
            for (prefix, key) in wanted where entry.starts(with: prefix) {
                environment[key] = String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
        }
        return (arguments, environment)
    }

    /// Only these environment variables are kept from a herdr process; the
    /// rest of its environment is never stored.
    static let environmentKeys: Set<String> = ["HOME", "XDG_CONFIG_HOME", "HERDR_SOCKET_PATH", "HERDR_SESSION"]

    static func processArguments(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)), keeping: environmentKeys)
    }

    static func processName(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    /// The herdr client in the foreground of a pty, if one is there.
    @MainActor
    static func client(inForegroundOf ptyDescriptor: Int32) -> HerdrClientKind? {
        guard let group = TerminalProcessInspector.foregroundProcessGroup(ptyDescriptor: ptyDescriptor),
              processName(group) == "herdr",
              let process = processArguments(of: group) else {
            return nil
        }
        return client(
            arguments: process.arguments,
            environment: process.environment,
            home: NSHomeDirectory()
        )
    }

    // MARK: Trust

    nonisolated enum Trust: Equatable, Sendable {
        /// Safe to connect to, at this resolved path.
        case trusted(String)
        case missing
        case refused(String)
    }

    /// The socket must be a socket owned by this user and writable by no one
    /// else, and every directory above it must be owned by this user or root
    /// and not writable by others (a sticky directory such as /tmp is fine:
    /// others cannot replace what is in it). Otherwise someone else could
    /// stand in for herdr. Symlinks are resolved first and the resolved path
    /// is what Moo connects to, so a link cannot be swapped after the check.
    @MainActor
    static func trust(socketPath: String, uid: uid_t = getuid()) -> Trust {
        let shown = TerminalNotificationParser.clean(socketPath, limit: 200)
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard let resolvedDirectory = realPath(directory) else { return .missing }
        let resolved = (resolvedDirectory as NSString)
            .appendingPathComponent((socketPath as NSString).lastPathComponent)

        var socketInfo = stat()
        guard lstat(resolved, &socketInfo) == 0 else { return .missing }
        guard socketInfo.st_mode & S_IFMT == S_IFSOCK else {
            return .refused("\(shown) is not a socket")
        }
        guard socketInfo.st_uid == uid else {
            return .refused("\(shown) belongs to another user")
        }
        guard socketInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return .refused("\(shown) can be written by other users")
        }

        var current = resolvedDirectory
        var isSocketDirectory = true
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else { return .missing }
            let shownDirectory = TerminalNotificationParser.clean(current, limit: 200)
            guard info.st_uid == uid || info.st_uid == 0 else {
                return .refused("\(shownDirectory) belongs to another user")
            }
            let othersCanWrite = info.st_mode & (S_IWGRP | S_IWOTH) != 0
            let isSticky = info.st_mode & S_ISVTX != 0
            if othersCanWrite && (isSocketDirectory || !isSticky) {
                return .refused("\(shownDirectory) can be written by other users")
            }
            isSocketDirectory = false
            guard current != "/" else { break }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
        return .trusted(resolved)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
