//
//  HerdrConnection.swift
//  Moo
//
//  One connection to a herdr socket: lines out, lines in. A plain Unix
//  socket read through a DispatchSource on its own queue; each batch of
//  complete lines crosses to the main thread with `DispatchQueue.main.async`,
//  never a Task, so lines arrive in the order herdr sent them.
//
//  Two properties matter here:
//  - Everything herdr wrote is read before the end is reported. herdr
//    answers a snapshot and hangs up at once; the reply must not be lost to
//    the hang-up. (NWConnection could report the hang-up first and drop a
//    large reply, which is why this is a plain socket.)
//  - The process on the other end must belong to this user (`getpeereid`),
//    checked on the connection itself, so no path trick can put another
//    user's server there.
//

import Darwin
import Foundation

nonisolated enum HerdrConnectionEnd: Equatable, Sendable {
    /// herdr closed the connection (the server stopped, or it answered a
    /// one-shot request and hung up).
    case closed
    /// A line longer than `HerdrProtocol.lineLimit`.
    case lineTooLong
    case failed(String)
}

nonisolated final class HerdrConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var ended = false
    private let onLine: @MainActor (Data) -> Void
    private let onEnd: @MainActor (HerdrConnectionEnd) -> Void

    /// Starts connecting at once. Callbacks run on the main thread; `onEnd`
    /// runs at most once. `cancel()` takes effect on the connection's queue,
    /// so a line or end already on its way can still arrive; callers ignore
    /// those (HerdrBridge checks its generation).
    init(
        socketPath: String,
        label: String,
        peerUID: uid_t = getuid(),
        onLine: @escaping @MainActor (Data) -> Void,
        onEnd: @escaping @MainActor (HerdrConnectionEnd) -> Void
    ) {
        self.onLine = onLine
        self.onEnd = onEnd
        queue = DispatchQueue(label: "net.vpetkov.Moo.herdr.\(label)")
        queue.async { [self] in open(socketPath, peerUID: peerUID) }
    }

    func send(_ request: HerdrRequest) {
        queue.async { [self] in
            guard !ended, socket >= 0 else { return }
            let bytes = [UInt8](request.data)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    // Requests are a few hundred bytes; a full buffer clears at once.
                    usleep(1_000)
                } else {
                    finish(.failed(String(cString: strerror(errno))))
                    return
                }
            }
        }
    }

    /// Closes the connection without reporting an end.
    func cancel() {
        queue.async { [self] in
            ended = true
            close()
        }
    }

    // MARK: On the queue

    private func open(_ path: String, peerUID: uid_t) {
        guard !ended else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return finish(.failed(String(cString: strerror(errno)))) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            return finish(.failed("The herdr socket path is too long."))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            return finish(.failed(reason))
        }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == peerUID else {
            Darwin.close(fd)
            return finish(.failed("The herdr socket is served by another user."))
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        self.source = source
        source.resume()
    }

    /// Reads until the socket would block, or to end of file.
    private func readAvailable() {
        guard !ended, socket >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if !deliverLines() { return }
                continue
            }
            if count == 0 {
                return finish(.closed)
            }
            if errno == EAGAIN || errno == EINTR {
                return
            }
            return finish(.failed(String(cString: strerror(errno))))
        }
    }

    /// Hands every complete line to the main thread in one hop, then drops
    /// them from the buffer once, rather than once per line. False when the
    /// connection ended.
    private func deliverLines() -> Bool {
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            guard newline - start <= HerdrProtocol.lineLimit else {
                finish(.lineTooLong)
                return false
            }
            lines.append(Data(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        if buffer.count > HerdrProtocol.lineLimit {
            finish(.lineTooLong)
            return false
        }
        guard !lines.isEmpty else { return true }
        let onLine = self.onLine
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in lines { onLine(line) }
            }
        }
        return true
    }

    private func finish(_ end: HerdrConnectionEnd) {
        guard !ended else { return }
        ended = true
        buffer.removeAll()
        close()
        let onEnd = self.onEnd
        DispatchQueue.main.async { MainActor.assumeIsolated { onEnd(end) } }
    }

    private func close() {
        if let source {
            // The source owns the descriptor from here: it closes it once
            // it has stopped watching.
            let fd = socket
            source.setCancelHandler { Darwin.close(fd) }
            source.cancel()
            self.source = nil
        } else if socket >= 0 {
            Darwin.close(socket)
        }
        socket = -1
    }
}

extension HerdrConnection {
    /// Sends one request and hands back the first line of the reply, or nil
    /// when the connection ends first or `timeout` passes.
    @MainActor
    static func request(
        socketPath: String,
        _ request: HerdrRequest,
        timeout: TimeInterval = 5,
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        var done = false
        var holder: HerdrConnection?
        let finish: @MainActor (Data?) -> Void = { reply in
            guard !done else { return }
            done = true
            holder?.cancel()
            holder = nil
            completion(reply)
        }
        holder = HerdrConnection(
            socketPath: socketPath,
            label: "request",
            onLine: { line in finish(line) },
            onEnd: { _ in finish(nil) }
        )
        holder?.send(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { finish(nil) }
        }
    }
}
