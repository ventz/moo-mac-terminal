//
//  FakeHerdrCoreServer.swift
//  MooTests
//
//  A stand-in herdr-core: a real Unix socket in a temporary directory that
//  speaks JSON-RPC 2.0 lines. It answers `events.subscribe` with a snapshot
//  and keeps the connection as a subscriber; tests push events, `missed`
//  and hang-ups. Never touches a real herdr-core or ~/.local/state.
//

import Darwin
import Foundation

final class FakeHerdrCoreServer: @unchecked Sendable {
    let directory: String
    let socketPath: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients: [Int32] = []
    private var subscribers: [Int32] = []
    private var _terminals: [[String: Any]]
    private var _seq: UInt64
    private var _methods: [String] = []
    private var _subscriptions = 0

    var methods: [String] { lock.withLock { _methods } }
    var subscriptionCount: Int { lock.withLock { _subscriptions } }
    var subscriberCount: Int { lock.withLock { subscribers.count } }
    var terminals: [[String: Any]] {
        get { lock.withLock { _terminals } }
        set { lock.withLock { _terminals = newValue } }
    }

    init(terminals: [[String: Any]] = [], seq: UInt64 = 10, sessionName: String = "default", root: String? = nil) throws {
        _terminals = terminals
        _seq = seq
        let base: String
        if let root {
            base = root
        } else {
            // Short: a Unix socket path must fit in 104 bytes.
            let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("hc.XXXXXX")
            var buffer = Array(template.utf8CString)
            guard mkdtemp(&buffer) != nil else { throw POSIXError(.EIO) }
            base = String(cString: buffer)
        }
        directory = (base as NSString).appendingPathComponent(sessionName)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        socketPath = (directory as NSString).appendingPathComponent("\(sessionName).sock")
        try listen()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(atPath: directory)
    }

    func stop() {
        lock.withLock {
            if listener >= 0 { close(listener); listener = -1 }
        }
        for fd in lock.withLock({ clients }) { hangUp(fd) }
    }

    // MARK: Fixtures

    static func terminal(
        _ address: String,
        state: String? = nil,
        app: String? = "claude-code",
        kind: String? = nil,
        place: String? = "api / 1",
        cwd: String = "/tmp/api"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "address": address, "argv": ["/bin/zsh", "-l"], "cols": 80, "rows": 24,
            "created_ms": 1, "cwd": cwd, "screen": "exact", "state": "live", "title": "",
            "foreground": ["argv": ["claude"], "cwd": cwd, "name": "2.1.0", "pid": 1],
            "labels": place.map { ["herdr.space": "sp1", "herdr.tab": "tb1", "where": $0] } ?? [:],
            "reported": state != nil, "turn": 0,
        ]
        if let state {
            var status: [String: Any] = ["state": state]
            if let app { status["app"] = app }
            if let kind { status["kind"] = kind }
            object["status"] = status
        } else {
            object["status"] = NSNull()
        }
        return object
    }

    // MARK: Scripting

    /// Pushes one `event` notification with the next sequence number.
    func push(_ type: String, terminal: String, data: [String: Any] = [:]) {
        let seq = lock.withLock { () -> UInt64 in _seq += 1; return _seq }
        broadcast(json(["jsonrpc": "2.0", "method": "event",
                        "params": ["type": type, "terminal": terminal, "seq": seq, "data": data]]))
    }

    func pushStatus(_ terminal: String, _ state: String?, app: String = "claude-code") {
        let status: Any = state.map { ["state": $0, "app": app] as [String: Any] } ?? NSNull()
        push("status", terminal: terminal, data: ["records": [:] as [String: Any], "reported": true, "status": status])
    }

    /// An event the subscriber has already seen: must be ignored.
    func pushStale(_ terminal: String, _ state: String) {
        let seq = lock.withLock { _seq }
        broadcast(json(["jsonrpc": "2.0", "method": "event",
                        "params": ["type": "status", "terminal": terminal, "seq": seq,
                                   "data": ["status": ["state": state]]]]))
    }

    func pushMissed() {
        broadcast(json(["jsonrpc": "2.0", "method": "missed", "params": [:] as [String: Any]]))
    }

    func hangUpSubscribers() {
        for fd in lock.withLock({ subscribers }) { hangUp(fd) }
    }

    private func broadcast(_ line: String) {
        for fd in lock.withLock({ subscribers }) { write(line, to: fd) }
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
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
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
        let id = request["id"] ?? NSNull()
        lock.withLock { _methods.append(method) }
        guard method == "events.subscribe", request["jsonrpc"] as? String == "2.0" else {
            write(json(["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32601, "message": "unknown method",
                                  "data": ["kind": "method_not_found"]]]), to: fd)
            return
        }
        let (terminals, seq) = lock.withLock { () -> ([[String: Any]], UInt64) in
            _subscriptions += 1
            subscribers.append(fd)
            return (_terminals, _seq)
        }
        write(json(["jsonrpc": "2.0", "id": id,
                    "result": ["channel": NSNull(), "seq": seq, "terminals": terminals]]), to: fd)
    }

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

    func hangUp(_ fd: Int32) {
        let wasOpen = lock.withLock { () -> Bool in
            guard clients.contains(fd) else { return false }
            clients.removeAll { $0 == fd }
            subscribers.removeAll { $0 == fd }
            return true
        }
        guard wasOpen else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
