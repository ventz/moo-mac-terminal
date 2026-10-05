//
//  FakeHerdrServer.swift
//  MooTests
//
//  A stand-in herdr: a real Unix socket in a temporary directory that
//  speaks herdr's newline JSON. Tests script it — panes and statuses, pushed
//  events, `events_lost`, oversized lines, hanging up — and never touch a
//  real herdr or ~/.config.
//

import Darwin
import Foundation

final class FakeHerdrServer: @unchecked Sendable {
    struct Pane {
        var id: String
        var workspace = "w1"
        var agent: String?
        var status = "unknown"
    }

    let directory: String
    let socketPath: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients: [Int32] = []
    private var lifecycleClients: [Int32] = []
    private var paneClients: [String: [Int32]] = [:]
    private var _panes: [Pane]
    private var _labels: [String: String]
    private var _methods: [String] = []
    private var _focused: [String] = []
    private var _snapshots = 0

    var panes: [Pane] {
        get { lock.withLock { _panes } }
        set { lock.withLock { _panes = newValue } }
    }
    var methods: [String] { lock.withLock { _methods } }
    var focusRequests: [String] { lock.withLock { _focused } }
    var snapshotCount: Int { lock.withLock { _snapshots } }
    var subscribedPanes: Set<String> { lock.withLock { Set(paneClients.filter { !$0.value.isEmpty }.keys) } }
    var lifecycleCount: Int { lock.withLock { lifecycleClients.count } }

    /// `directory`: serve from there instead of a new temporary directory
    /// (which the server then does not delete).
    init(panes: [Pane] = [], labels: [String: String] = ["w1": "api"], directory: String? = nil) throws {
        _panes = panes
        _labels = labels
        if let directory {
            self.directory = directory
            ownsDirectory = false
        } else {
            // Short: a Unix socket path must fit in 104 bytes.
            let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("hf.XXXXXX")
            var buffer = Array(template.utf8CString)
            guard mkdtemp(&buffer) != nil else { throw POSIXError(.EIO) }
            self.directory = String(cString: buffer)
            ownsDirectory = true
        }
        socketPath = (self.directory as NSString).appendingPathComponent("herdr.sock")
        try listen()
    }

    private let ownsDirectory: Bool

    deinit {
        stop()
        if ownsDirectory {
            try? FileManager.default.removeItem(atPath: directory)
        } else {
            unlink(socketPath)
        }
    }

    func stop() {
        lock.withLock {
            if listener >= 0 { close(listener); listener = -1 }
        }
        for fd in lock.withLock({ clients }) { hangUp(fd) }
    }

    // MARK: Scripting

    func pushStatus(_ paneID: String, _ status: String, agent: String = "claude") {
        lock.withLock {
            if let index = _panes.firstIndex(where: { $0.id == paneID }) {
                _panes[index].status = status
                _panes[index].agent = agent
            }
        }
        let line = json(["event": "pane.agent_status_changed",
                         "data": ["agent": agent, "agent_status": status, "pane_id": paneID, "workspace_id": "w1"]])
        for fd in lock.withLock({ paneClients[paneID] ?? [] }) { write(line, to: fd) }
    }

    func pushLifecycle(_ line: String) {
        for fd in lock.withLock({ lifecycleClients }) { write(line, to: fd) }
    }

    func addPane(_ pane: Pane) {
        lock.withLock { _panes.append(pane) }
        pushLifecycle(json(["event": "pane_created",
                            "data": ["type": "pane_created",
                                     "pane": ["pane_id": pane.id, "workspace_id": pane.workspace,
                                              "agent_status": pane.status]]]))
    }

    /// herdr noticing an agent in a pane (what makes Moo subscribe to it).
    func detectAgent(_ paneID: String, _ agent: String = "claude") {
        lock.withLock {
            if let index = _panes.firstIndex(where: { $0.id == paneID }) { _panes[index].agent = agent }
        }
        pushLifecycle(json(["event": "pane_agent_detected",
                            "data": ["type": "pane_agent_detected", "agent": agent, "pane_id": paneID, "workspace_id": "w1"]]))
    }

    func closePane(_ id: String) {
        lock.withLock { _panes.removeAll { $0.id == id } }
        pushLifecycle(json(["event": "pane_closed", "data": ["type": "pane_closed", "pane_id": id, "workspace_id": "w1"]]))
    }

    // MARK: Serving

    private func listen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(socketPath, 0o600)
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clients.append(client) }
            Thread.detachNewThread { [weak self] in self?.readLoop(client) }
        }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                hangUp(fd)
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(Data(line), on: fd)
            }
        }
    }

    private func handle(_ line: Data, on fd: Int32) {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = request["method"] as? String else { return }
        let id = request["id"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        lock.withLock { _methods.append(method) }
        switch method {
        case "events.subscribe":
            let subscriptions = params["subscriptions"] as? [[String: String]] ?? []
            if let paneID = subscriptions.first(where: { $0["type"] == "pane.agent_status_changed" })?["pane_id"] {
                guard lock.withLock({ _panes.contains { $0.id == paneID } }) else {
                    write(json(["id": id, "error": ["code": "pane_not_found", "message": "pane \(paneID) not found"]]), to: fd)
                    hangUp(fd)
                    return
                }
                lock.withLock { paneClients[paneID, default: []].append(fd) }
            } else {
                lock.withLock { lifecycleClients.append(fd) }
            }
            write(json(["id": id, "result": ["type": "subscription_started"]]), to: fd)
        case "session.snapshot":
            write(snapshotLine(id: id), to: fd)
            hangUp(fd)
        case "pane.focus":
            lock.withLock { _focused.append(params["pane_id"] as? String ?? "") }
            write(json(["id": id, "result": ["type": "pane_info"]]), to: fd)
            hangUp(fd)
        default:
            write(json(["id": id, "error": ["code": "invalid_request", "message": "unknown method"]]), to: fd)
            hangUp(fd)
        }
    }

    private func snapshotLine(id: String) -> String {
        let (panes, labels) = lock.withLock { () -> ([Pane], [String: String]) in
            _snapshots += 1
            return (_panes, _labels)
        }
        let paneObjects: [[String: Any]] = panes.map { pane in
            var object: [String: Any] = ["pane_id": pane.id, "workspace_id": pane.workspace, "agent_status": pane.status]
            if let agent = pane.agent { object["agent"] = agent }
            return object
        }
        let agents: [[String: Any]] = panes.compactMap { pane in
            guard let agent = pane.agent else { return nil }
            return ["pane_id": pane.id, "agent": agent, "agent_status": pane.status, "workspace_id": pane.workspace]
        }
        let workspaces: [[String: Any]] = labels.map { ["workspace_id": $0.key, "label": $0.value] }
        return json(["id": id, "result": ["type": "session_snapshot", "snapshot": [
            "version": "0.9.3", "panes": paneObjects, "agents": agents, "workspaces": workspaces,
            "focused_pane_id": panes.first?.id ?? "",
        ]]])
    }

    /// Writes the whole line: a socket may take a large one in pieces.
    func write(_ line: String, to fd: Int32) {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return
            }
        }
    }

    /// Closes a client once, whoever notices first: the server hanging up,
    /// or the client going away.
    func hangUp(_ fd: Int32) {
        let wasOpen = lock.withLock { () -> Bool in
            guard clients.contains(fd) else { return false }
            clients.removeAll { $0 == fd }
            lifecycleClients.removeAll { $0 == fd }
            for key in paneClients.keys { paneClients[key]?.removeAll { $0 == fd } }
            return true
        }
        guard wasOpen else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    func hangUpLifecycle() {
        for fd in lock.withLock({ lifecycleClients }) { hangUp(fd) }
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
