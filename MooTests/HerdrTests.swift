//
//  HerdrTests.swift
//  MooTests
//

import Darwin
import Foundation
import Testing
@testable import Moo

private func line(_ text: String) -> Data { Data(text.utf8) }

/// Polls until `condition` holds, yielding the main thread so callbacks the
/// bridge dispatched there can run.
@MainActor
private func waitUntil(
    _ what: String,
    timeout: TimeInterval = 10,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - Protocol

struct HerdrProtocolTests {
    @Test func parsesACapturedSnapshot() throws {
        guard case .snapshot(let id, let snapshot)? = HerdrProtocol.parse(line(HerdrFixtures.snapshotWithBlockedAgent)) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(id == "s1")
        #expect(snapshot.version == "0.9.3")
        #expect(snapshot.focusedPaneID == "w1:p1")
        #expect(snapshot.workspaceLabels == ["w1": "api"])
        #expect(snapshot.panes == [HerdrPane(paneID: "w1:p1", workspaceID: "w1", agent: "claude", status: .blocked)])
    }

    @Test func acceptsBothEventSpellings() {
        #expect(HerdrProtocol.parse(line(HerdrFixtures.statusBlocked))
            == .event(.statusChanged(paneID: "w1:p1", agent: "claude", status: .blocked)))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.paneCreated))
            == .event(.paneCreated(HerdrPane(paneID: "w1:p2", workspaceID: "w1", agent: nil, status: .unknown))))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.paneClosed)) == .event(.paneClosed(paneID: "w1:p2")))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.agentDetected))
            == .event(.agentDetected(paneID: "w1:p1", agent: "claude", released: false)))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.agentReleased))
            == .event(.agentDetected(paneID: "w1:p4", agent: "claude", released: true)))
    }

    @Test func parsesRepliesAndErrors() {
        #expect(HerdrProtocol.parse(line(HerdrFixtures.subscriptionStarted))
            == .response(id: "status", type: "subscription_started"))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.agentFocusReply)) == .response(id: "f2", type: "agent_info"))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.unknownPaneSubscribe))
            == .error(id: "e1", code: "pane_not_found", message: "pane w9:p9 not found"))
        #expect(HerdrProtocol.parse(line(HerdrFixtures.eventsLost))
            == .error(id: "lifecycle", code: "events_lost", message: "subscriber fell behind"))
        #expect(HerdrProtocol.parse(line("not json")) == nil)
    }

    @Test func unknownStatusesReadAsUnknown() {
        #expect(HerdrAgentStatus(raw: "thinking") == .unknown)
        #expect(HerdrAgentStatus(raw: nil) == .unknown)
        #expect(HerdrAgentStatus.done.isAtRest && HerdrAgentStatus.idle.isAtRest)
        #expect(!HerdrAgentStatus.working.isAtRest)
    }

    /// The socket can type into panes; Moo must never be able to ask it to.
    @Test func onlyReadAndFocusMethodsExist() {
        #expect(Set(HerdrMethod.allCases.map(\.rawValue))
            == ["ping", "session.snapshot", "events.subscribe", "pane.focus", "agent.focus"])
    }

    @Test func herdrSourceNeverNamesAnInputMethod() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moo/Herdr")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 5)
        // As string literals: the form a request would need. ("pane.closed"
        // is an event Moo subscribes to, not "pane.close".)
        let forbidden = ["pane.send_text", "pane.send_keys", "pane.send_input", "agent.send_keys",
                         "agent.prompt", "pane.run", "pane.close", "pane.split", "server.stop",
                         "agent.start", "integration.install", "plugin.action.invoke"]
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for name in forbidden {
                #expect(!source.contains("\"\(name)\""), "\(file) names \(name)")
            }
            #expect(!source.contains("send_text") && !source.contains("send_keys"), "\(file)")
        }
    }

    @Test func requestsAreOneLine() throws {
        let data = HerdrProtocol.request(id: "a\nb", .paneFocus, params: ["pane_id": "w1:p1\n"]).data
        #expect(data.last == 0x0A)
        #expect(data.filter { $0 == 0x0A }.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        #expect(object["method"] as? String == "pane.focus")
    }

    @Test func versionCheck() throws {
        let current = try #require(HerdrProtocol.version(fromVersionOutput: "herdr 0.9.3\n"))
        #expect(current == (0, 9, 3))
        #expect(HerdrProtocol.isSupported(current))
        #expect(!HerdrProtocol.isSupported(try #require(HerdrProtocol.version(fromVersionOutput: "herdr 0.8.12"))))
        #expect(HerdrProtocol.isSupported(try #require(HerdrProtocol.version(fromVersionOutput: "herdr 1.0"))))
        #expect(HerdrProtocol.version(fromVersionOutput: "command not found") == nil)
    }
}

// MARK: - Discovery

struct HerdrDiscoveryTests {
    let home = "/Users/someone"

    func client(_ arguments: [String], _ environment: [String: String] = [:]) -> HerdrClientKind? {
        HerdrDiscovery.client(arguments: arguments, environment: environment, home: home)
    }

    func local(_ path: String, _ session: String? = nil) -> HerdrClientKind {
        .local(HerdrEndpoint(socketPath: path, sessionName: session))
    }

    @Test func plainHerdrUsesTheDefaultSession() {
        #expect(client(["herdr"]) == local("/Users/someone/.config/herdr/herdr.sock"))
        #expect(client(["/opt/homebrew/bin/herdr", "-v"]) == local("/Users/someone/.config/herdr/herdr.sock"))
        #expect(client(["herdr"], ["HOME": "/Users/other"]) == local("/Users/other/.config/herdr/herdr.sock"))
        #expect(client(["herdr"], ["XDG_CONFIG_HOME": "/tmp/xdg"]) == local("/tmp/xdg/herdr/herdr.sock"))
    }

    @Test func namedSessions() {
        let work = local("/Users/someone/.config/herdr/sessions/work/herdr.sock", "work")
        #expect(client(["herdr", "--session", "work"]) == work)
        #expect(client(["herdr", "--session=work"]) == work)
        #expect(client(["herdr", "session", "attach", "work"]) == work)
        #expect(client(["herdr"], ["HERDR_SESSION": "work"]) == work)
        #expect(client(["herdr"], ["HERDR_SESSION": "default"]) == local("/Users/someone/.config/herdr/herdr.sock"))
        #expect(work.endpoint?.attachCommand == "herdr session attach work")
    }

    /// herdr 0.9: an explicit session beats HERDR_SOCKET_PATH, which beats
    /// HERDR_SESSION.
    @Test func precedenceMatchesHerdr() {
        let environment = ["HERDR_SOCKET_PATH": "/tmp/custom.sock", "HERDR_SESSION": "env"]
        #expect(client(["herdr", "--session", "flag"], environment)
            == local("/Users/someone/.config/herdr/sessions/flag/herdr.sock", "flag"))
        #expect(client(["herdr"], environment)
            == .local(HerdrEndpoint(socketPath: "/tmp/custom.sock", sessionName: nil, isSocketOverride: true)))
        // Relative to the client's directory, which Moo cannot know.
        #expect(client(["herdr"], ["HERDR_SOCKET_PATH": "run/herdr.sock"]) == nil)
        // A new shell would not find an override socket, so no reattach.
        #expect(client(["herdr"], environment)?.endpoint?.attachCommand == nil)
    }

    @Test func remoteAndOneShotCommands() {
        #expect(client(["herdr", "--remote", "workbox"]) == .remote(host: "workbox"))
        #expect(client(["herdr", "--remote=workbox", "--session", "a"]) == .remote(host: "workbox"))
        #expect(client(["herdr", "pane", "list"]) == nil)
        #expect(client(["herdr", "agent", "attach", "reviewer"]) == nil)
        #expect(client(["herdr", "server"]) == nil)
    }

    /// A session name becomes a path component.
    @Test func sessionNamesCannotLeaveTheSessionsDirectory() {
        for name in ["..", ".", "../../etc", "a/b", "", "x y", "-v", "--handoff", ".hidden",
                     "a;rm", "a$(x)", String(repeating: "a", count: 65)] {
            #expect(client(["herdr", "--session", name]) == nil, "accepted \(name)")
            #expect(client(["herdr"], ["HERDR_SESSION": name]) == nil || name.isEmpty, "accepted \(name)")
        }
        #expect(HerdrDiscovery.isValidSessionName("agents-2.work_x"))
    }

    @Test func parsesProcessArgumentsAndEnvironment() throws {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
        buffer += Array("/opt/homebrew/bin/herdr".utf8) + [0, 0, 0]
        for argument in ["herdr", "--session", "work"] { buffer += Array(argument.utf8) + [0] }
        for entry in ["HOME=/Users/a", "TOKEN=secret", "HERDR_SESSION=x=y"] { buffer += Array(entry.utf8) + [0] }
        buffer += [0]
        let parsed = try #require(HerdrDiscovery.parseProcessArguments(buffer, keeping: ["HOME", "HERDR_SESSION"]))
        #expect(parsed.arguments == ["herdr", "--session", "work"])
        // TOKEN is never decoded.
        #expect(parsed.environment == ["HOME": "/Users/a", "HERDR_SESSION": "x=y"])
        #expect(HerdrDiscovery.parseProcessArguments([1, 2], keeping: []) == nil)
    }

    /// Only the variables that pick a socket are kept from a real process.
    @Test func keepsOnlyTheSocketVariablesOfARealProcess() throws {
        let own = try #require(HerdrDiscovery.processArguments(of: getpid()))
        #expect(!own.arguments.isEmpty)
        #expect(Set(own.environment.keys).isSubset(of: HerdrDiscovery.environmentKeys))
    }
}

extension HerdrClientKind {
    var endpoint: HerdrEndpoint? {
        if case .local(let endpoint) = self { return endpoint }
        return nil
    }
}

// MARK: - Trust

@MainActor
struct HerdrSocketTrustTests {
    @Test func trustsOnlyAPrivateSocketInAPrivateDirectory() throws {
        let server = try FakeHerdrServer()
        guard case .trusted(let resolved) = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a private socket was not trusted")
            return
        }
        #expect(resolved.hasSuffix("/herdr.sock"))
        #expect(HerdrDiscovery.trust(socketPath: server.directory + "/none.sock") == .missing)

        guard case .refused = HerdrDiscovery.trust(socketPath: server.socketPath, uid: getuid() + 1) else {
            Issue.record("another user's socket was trusted")
            return
        }

        chmod(server.socketPath, 0o666)
        guard case .refused = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a world-writable socket was trusted")
            return
        }
        chmod(server.socketPath, 0o600)

        chmod(server.directory, 0o777)
        defer { chmod(server.directory, 0o700) }
        guard case .refused = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a socket in a world-writable directory was trusted")
            return
        }
    }

    /// A directory above the socket that others can write to (and that is
    /// not sticky, like /tmp) lets them swap the path after the check.
    @Test func refusesAWritableAncestor() throws {
        let outer = try FakeHerdrServer()
        let middle = outer.directory + "/m"
        let inner = middle + "/i"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        chmod(inner, 0o700)
        let server = try FakeHerdrServer(directory: inner)
        chmod(middle, 0o700)
        guard case .trusted = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a private chain was not trusted")
            return
        }

        chmod(middle, 0o777)
        defer { chmod(middle, 0o700) }
        guard case .refused(let reason) = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a writable ancestor was trusted")
            return
        }
        #expect(reason.contains("can be written by other users"))

        // Sticky, like /tmp: others cannot replace what is in it.
        chmod(middle, 0o1777)
        guard case .trusted = HerdrDiscovery.trust(socketPath: server.socketPath) else {
            Issue.record("a sticky ancestor was refused")
            return
        }
    }

    /// A symlinked directory is followed once, and the real path is what Moo
    /// connects to.
    @Test func connectsToTheResolvedPath() throws {
        let server = try FakeHerdrServer()
        let link = server.directory + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: server.directory)
        defer { try? FileManager.default.removeItem(atPath: link) }
        guard case .trusted(let resolved) = HerdrDiscovery.trust(socketPath: link + "/herdr.sock") else {
            Issue.record("a link to a private socket was not trusted")
            return
        }
        #expect(!resolved.contains("-link"))
    }

    @Test func refusesSomethingThatIsNotASocket() throws {
        let server = try FakeHerdrServer()
        let file = server.directory + "/herdr-file.sock"
        FileManager.default.createFile(atPath: file, contents: Data())
        chmod(file, 0o600)
        guard case .refused = HerdrDiscovery.trust(socketPath: file) else {
            Issue.record("a regular file was trusted")
            return
        }
    }
}

// MARK: - Bridge

/// The suites that open real sockets run one at a time: they share the
/// app-wide cap on status connections, and timing under the full suite's
/// parallel load is otherwise what they would be testing.
@Suite(.serialized)
struct HerdrSocketSuites {}

extension HerdrSocketSuites {
@MainActor
struct HerdrBridgeTests {
    func bridge(for server: FakeHerdrServer) -> (HerdrBridge, () -> [HerdrBridgeChange]) {
        let bridge = HerdrBridge(endpoint: HerdrEndpoint(socketPath: server.socketPath, sessionName: nil))
        var changes: [HerdrBridgeChange] = []
        bridge.onChange = { changes.append($0) }
        return (bridge, { changes.filter { if case .status = $0 { return true } else { return false } } })
    }

    @Test func loadsTheSnapshotThenFollowsStatus() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "idle")])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live && server.subscribedPanes == ["w1:p1"] }
        #expect(bridge.panes["w1:p1"]?.status == .idle)
        #expect(bridge.workspaceLabels["w1"] == "api")
        #expect(server.methods.first == "events.subscribe")

        server.pushStatus("w1:p1", "working")
        server.pushStatus("w1:p1", "blocked")
        try await waitUntil("blocked") { bridge.panes["w1:p1"]?.status == .blocked }
        #expect(statuses() == [
            .status(paneID: "w1:p1", agent: "claude", from: .unknown, to: .idle),
            .status(paneID: "w1:p1", agent: "claude", from: .idle, to: .working),
            .status(paneID: "w1:p1", agent: "claude", from: .working, to: .blocked),
        ])
    }

    @Test func followsPanesComingAndGoing() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "idle")])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }

        server.addPane(.init(id: "w1:p2"))
        try await Task.sleep(nanoseconds: 300_000_000)
        // No agent, no status connection.
        #expect(server.subscribedPanes == ["w1:p1"])
        server.detectAgent("w1:p2", "codex")
        try await waitUntil("second pane subscribed") { server.subscribedPanes == ["w1:p1", "w1:p2"] }
        server.pushStatus("w1:p2", "working", agent: "codex")
        try await waitUntil("codex working") { bridge.panes["w1:p2"]?.status == .working }
        #expect(bridge.panes["w1:p2"]?.agent == "codex")

        server.closePane("w1:p2")
        try await waitUntil("pane gone") { bridge.panes["w1:p2"] == nil }
        #expect(statuses().last == .status(paneID: "w1:p2", agent: "codex", from: .working, to: .unknown))
    }

    /// Missed events cannot leave a stale status: the bridge resubscribes and
    /// takes a new snapshot, and only real differences are reported.
    @Test func eventsLostResynchronizes() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live && server.subscribedPanes == ["w1:p1"] }
        // Past the snapshot that follows the first subscription.
        try await waitUntil("reconciled") { server.snapshotCount >= 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        let snapshots = server.snapshotCount

        // The agent blocked while the subscriber fell behind.
        server.panes = [.init(id: "w1:p1", agent: "claude", status: "blocked")]
        server.pushLifecycle(HerdrFixtures.eventsLost)
        try await waitUntil("resynchronized") {
            server.snapshotCount > snapshots && bridge.panes["w1:p1"]?.status == .blocked
        }
        #expect(statuses() == [
            .status(paneID: "w1:p1", agent: "claude", from: .unknown, to: .working),
            .status(paneID: "w1:p1", agent: "claude", from: .working, to: .blocked),
        ])
    }

    /// A status can change after the snapshot and before that pane's own
    /// subscription is in place. herdr sends no event for it then, so each
    /// new subscription is followed by one more snapshot.
    @Test func aStatusChangedBeforeItsSubscriptionIsStillSeen() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live && server.subscribedPanes == ["w1:p1"] }
        // The snapshot that follows the first subscription has happened.
        try await waitUntil("reconciled") { server.snapshotCount >= 2 }

        // Changed in the gap: no event reaches the bridge.
        server.panes[0].status = "blocked"
        server.addPane(.init(id: "w1:p2"))
        server.detectAgent("w1:p2")
        try await waitUntil("caught up") { bridge.panes["w1:p1"]?.status == .blocked }
    }

    @Test func dropsAConnectionThatSendsAnOversizedLine() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "idle")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }

        server.pushLifecycle(String(repeating: "x", count: HerdrProtocol.lineLimit + 10))
        try await waitUntil("dropped") {
            if case .unavailable = bridge.state { return true } else { return false }
        }
        #expect(bridge.panes.isEmpty)
        // It comes back on its own once herdr behaves.
        try await waitUntil("reconnected") { bridge.state == .live }
    }

    @Test func aServerThatGoesAwayClearsThePanes() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "idle")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        server.stop()
        try await waitUntil("unavailable") {
            if case .unavailable = bridge.state { return true } else { return false }
        }
        #expect(bridge.panes.isEmpty)
    }

    @Test func aRefusedSocketIsNeverOpened() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1")])
        let (bridge, _) = bridge(for: server)
        bridge.trust = { _ in .refused("not yours\u{202E}\nConnected") }
        bridge.start()
        defer { bridge.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard case .refused(let reason) = bridge.state else {
            Issue.record("not refused")
            return
        }
        #expect(!reason.contains("\n") && !reason.contains("\u{202E}"))
        #expect(server.methods.isEmpty)
    }

    /// Every status subscription is a file descriptor; a session with
    /// hundreds of agents (or a hostile server) must not exhaust them.
    @Test func capsStatusConnections() async throws {
        let panes = (1...200).map { FakeHerdrServer.Pane(id: "w1:p\($0)", agent: "claude", status: "idle") }
        let server = try FakeHerdrServer(panes: panes)
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live && bridge.panes.count == 200 }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(server.subscribedPanes.count == HerdrBridge.paneConnectionLimit)
    }

    /// A socket that stops passing the check, or resolves somewhere else,
    /// gets no further connections.
    @Test func aSwappedSocketEndsTheSession() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "idle")])
        let (bridge, _) = bridge(for: server)
        var verdict = HerdrDiscovery.Trust.missing
        bridge.trust = { path in
            if case .missing = verdict { verdict = HerdrDiscovery.trust(socketPath: path) }
            return verdict
        }
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        let before = server.methods.count
        verdict = .trusted("/somewhere/else.sock")
        bridge.focus(paneID: "w1:p1")
        try await waitUntil("ended") {
            if case .unavailable = bridge.state { return true } else { return false }
        }
        #expect(server.methods.count == before)
        #expect(server.focusRequests.isEmpty)
    }

    /// The process serving the socket must be this user, checked on the
    /// connection itself (getpeereid), not only on the path.
    @Test func aServerRunByAnotherUserIsRefused() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1")])
        var ended: HerdrConnectionEnd?
        let connection = HerdrConnection(
            socketPath: server.socketPath,
            label: "test",
            peerUID: getuid() + 1,
            onLine: { _ in },
            onEnd: { ended = $0 }
        )
        connection.send(HerdrProtocol.request(id: "p", .ping))
        try await waitUntil("refused") { ended != nil }
        #expect(ended == .failed("The herdr socket is served by another user."))
        #expect(server.methods.isEmpty)
    }

    /// A large reply followed at once by a hang-up is read in full.
    @Test func aLargeReplyIsReadBeforeTheHangUp() async throws {
        let panes = (1...400).map { FakeHerdrServer.Pane(id: "w1:p\($0)", agent: "claude", status: "idle") }
        let server = try FakeHerdrServer(panes: panes)
        var reply: Data?
        var done = false
        HerdrConnection.request(socketPath: server.socketPath, HerdrProtocol.request(id: "s", .snapshot)) {
            reply = $0
            done = true
        }
        try await waitUntil("reply") { done }
        let data = try #require(reply)
        guard case .snapshot(_, let snapshot)? = HerdrProtocol.parse(data) else {
            Issue.record("not a snapshot (\(data.count) bytes)")
            return
        }
        #expect(snapshot.panes.count == 400)
    }

    @Test func focusAsksHerdrToFocusThePane() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude"), .init(id: "w1:p2", agent: "codex")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        bridge.focus(paneID: "w1:p2")
        try await waitUntil("focused") { server.focusRequests == ["w1:p2"] }
        #expect(Set(server.methods).isSubset(of: Set(HerdrMethod.allCases.map(\.rawValue))))
    }
}

}

// MARK: - Monitor

extension HerdrSocketSuites {
@MainActor
struct HerdrMonitorTests {
    let host = UUID()
    let project = UUID()

    func monitor(
        server: FakeHerdrServer,
        hosts: @escaping () -> [UUID: HerdrClientKind],
        finished: Bool = false
    ) -> (HerdrMonitor, AttentionCenter) {
        let center = AttentionCenter(integratesWithSystem: false)
        let monitor = HerdrMonitor()
        monitor.attention = center
        monitor.scanHosts = hosts
        let project = self.project
        monitor.projectForHost = { _ in project }
        monitor.isLookingAtHost = { _ in false }
        monitor.locationOfHost = { _ in "Project › herdr" }
        monitor.alertsWhenBlocked = { true }
        monitor.alertsWhenFinished = { finished }
        return (monitor, center)
    }

    /// A clock the test moves by hand.
    final class Clock { var now = Date(timeIntervalSinceReferenceDate: 0) }

    func endpoint(_ server: FakeHerdrServer) -> HerdrClientKind {
        .local(HerdrEndpoint(socketPath: server.socketPath, sessionName: nil))
    }

    @Test func blockedAgentsPostOneLabeledEntryAndClearWhenAnswered() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let kind = endpoint(server)
        let host = self.host
        let (monitor, center) = monitor(server: server, hosts: { [host: kind] })
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("row") { monitor.rows(for: project).first?.status == .working }
        try await waitUntil("subscribed") { server.subscribedPanes == ["w1:p1"] }
        #expect(center.items.isEmpty)

        server.pushStatus("w1:p1", "blocked")
        try await waitUntil("entry") { center.unreadCount == 1 }
        let item = try #require(center.items.first)
        #expect(item.source == .herdr)
        #expect(item.surfaceID == host)
        #expect(item.title == "herdr: claude needs you")
        #expect(item.body == "api · detected by herdr")
        #expect(monitor.rows(for: project).first?.statusText == "needs you")

        server.pushStatus("w1:p1", "working")
        try await waitUntil("answered") { center.unreadCount == 0 }
    }

    /// A flapping agent, or a hostile server, gets one alert per pane per
    /// 30 seconds, and a session at most 10 a minute.
    @Test func alertsAreRateLimited() async throws {
        let panes = (1...12).map { FakeHerdrServer.Pane(id: "w1:p\($0)", agent: "claude", status: "working") }
        let server = try FakeHerdrServer(panes: panes)
        let kind = endpoint(server)
        let host = self.host
        let (monitor, center) = monitor(server: server, hosts: { [host: kind] })
        let clock = Clock()
        monitor.now = { clock.now }
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("rows") { monitor.rows(for: project).count == 12 }
        try await waitUntil("subscribed") { server.subscribedPanes.count == 12 }

        for _ in 0..<5 {
            server.pushStatus("w1:p1", "blocked")
            server.pushStatus("w1:p1", "working")
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(center.items.count == 1)

        for index in 2...12 { server.pushStatus("w1:p\(index)", "blocked") }
        try await waitUntil("all blocked") { monitor.rows(for: project).filter { $0.status == .blocked }.count == 11 }
        #expect(center.items.count == HerdrMonitor.sessionAlertLimit)

        clock.now += 61
        server.pushStatus("w1:p1", "blocked")
        try await waitUntil("allowed again") { center.items.count == HerdrMonitor.sessionAlertLimit + 1 }
    }

    /// Two agents with the same name in one workspace each get their own
    /// entry, and answering one leaves the other standing.
    @Test func twoAgentsWithTheSameNameGetTheirOwnEntries() async throws {
        let server = try FakeHerdrServer(panes: [
            .init(id: "w1:p1", agent: "claude", status: "working"),
            .init(id: "w1:p2", agent: "claude", status: "working"),
        ])
        let kind = endpoint(server)
        let host = self.host
        let (monitor, center) = monitor(server: server, hosts: { [host: kind] })
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("subscribed") { server.subscribedPanes.count == 2 }
        server.pushStatus("w1:p1", "blocked")
        server.pushStatus("w1:p2", "blocked")
        try await waitUntil("two entries") { center.unreadCount == 2 }
        server.pushStatus("w1:p1", "working")
        try await waitUntil("one answered") { center.unreadCount == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(center.unreadCount == 1)
        server.pushStatus("w1:p2", "working")
        try await waitUntil("both answered") { center.unreadCount == 0 }
    }

    /// A dropped connection must not leave a "needs you" behind that nothing
    /// will ever clear.
    @Test func aLostServerClearsItsEntries() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let kind = endpoint(server)
        let host = self.host
        let (monitor, center) = monitor(server: server, hosts: { [host: kind] })
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("subscribed") { server.subscribedPanes == ["w1:p1"] }
        server.pushStatus("w1:p1", "blocked")
        try await waitUntil("entry") { center.unreadCount == 1 }
        server.stop()
        try await waitUntil("cleared") { center.unreadCount == 0 }
        #expect(monitor.rows(for: project).isEmpty)
    }

    /// The 2 s scan must not redraw the sidebar when nothing changed.
    @Test func anUnchangedScanDoesNotRedraw() throws {
        let server = try FakeHerdrServer()
        let (monitor, _) = monitor(server: server, hosts: { [:] })
        monitor.start()
        defer { monitor.stop() }
        let revision = monitor.revision
        monitor.scan()
        monitor.scan()
        #expect(monitor.revision == revision)
    }

    @Test func finishedTurnsAlertOnlyWhenAskedTo() async throws {
        for alerts in [false, true] {
            let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
            let kind = endpoint(server)
            let host = self.host
            let (monitor, center) = monitor(server: server, hosts: { [host: kind] }, finished: alerts)
            monitor.start()
            defer { monitor.stop() }
            try await waitUntil("row") { monitor.rows(for: project).first?.status == .working }
            server.pushStatus("w1:p1", "idle")
            try await waitUntil("finished row") { monitor.rows(for: project).first?.statusText == "finished" }
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(center.unreadCount == (alerts ? 1 : 0))
            #expect(center.items.first?.title == (alerts ? "herdr: claude finished" : nil))
        }
    }

    @Test func rowsGoDetachedThenAwayWithTheServer() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let kind = endpoint(server)
        let host = self.host
        var hosting = true
        let (monitor, _) = monitor(server: server, hosts: { hosting ? [host: kind] : [:] })
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("row") { monitor.rows(for: project).count == 1 }
        #expect(monitor.rows(for: UUID()).isEmpty)

        hosting = false
        monitor.scan()
        #expect(monitor.rows(for: project).first?.isDetached == true)
        #expect(monitor.rows(for: project).first?.statusText == "detached")

        server.stop()
        try await waitUntil("gone") { monitor.rows(for: project).isEmpty }
    }

    @Test func remoteClientsAreCountedNotConnected() throws {
        let server = try FakeHerdrServer()
        let host = self.host
        let (monitor, _) = monitor(server: server, hosts: { [host: .remote(host: "workbox")] })
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.remoteHostCount == 1)
        #expect(monitor.liveSessionCount == 0)
        #expect(server.methods.isEmpty)
    }

    @Test func turningItOffDisconnects() async throws {
        let server = try FakeHerdrServer(panes: [.init(id: "w1:p1", agent: "claude", status: "working")])
        let kind = endpoint(server)
        let host = self.host
        let (monitor, _) = monitor(server: server, hosts: { [host: kind] })
        monitor.start()
        try await waitUntil("row") { monitor.rows(for: project).count == 1 }
        monitor.stop()
        #expect(monitor.rows(for: project).isEmpty)
        try await waitUntil("disconnected") { server.lifecycleCount == 0 && server.subscribedPanes.isEmpty }
    }

    @Test func agentNamesAreCleanedLikeTitles() {
        #expect(HerdrMonitor.clean("claude\u{202E}evil\nline") == TerminalNotificationParser.clean("claude\u{202E}evil\nline", limit: 60))
        #expect(HerdrMonitor.clean(String(repeating: "a", count: 500)).count <= 61)
    }
}

}

// MARK: - Installation

struct HerdrInstallationTests {
    /// A program whose child keeps stdout open must not hang the check.
    @Test func aHeldPipeCannotHangTheCheck() throws {
        let directory = NSTemporaryDirectory() + "herdr-install-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let script = directory + "/herdr"
        try "#!/bin/sh\necho 'herdr 0.9.3'\nsleep 30 &\nexit 0\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let started = Date()
        let output = HerdrInstallation.run(script, arguments: ["--version"], timeout: 2)
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(output?.contains("herdr 0.9.3") == true)
    }

    @Test func aHungProgramIsKilledAtTheDeadline() throws {
        let directory = NSTemporaryDirectory() + "herdr-install-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let script = directory + "/herdr"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let started = Date()
        #expect(HerdrInstallation.run(script, arguments: ["--version"], timeout: 1) == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }
}

// MARK: - Attention entries

@MainActor
struct HerdrAttentionTests {
    /// herdr's entries never fold into a program's, even with the same words.
    @Test func programAndHerdrEntriesStaySeparate() {
        let center = AttentionCenter(integratesWithSystem: false)
        let surface = UUID()
        let words = TerminalNotification(title: "claude needs you", body: "api")
        center.record(words, surfaceID: surface, location: "here")
        center.record(words, surfaceID: surface, location: "here", source: .herdr, repeatKey: "s#w1:p1")
        center.record(words, surfaceID: surface, location: "here", source: .herdr, repeatKey: "s#w1:p2")
        #expect(center.items.count == 3)
        // A repeat from the same agent refreshes its entry.
        center.record(words, surfaceID: surface, location: "here", source: .herdr, repeatKey: "s#w1:p1")
        #expect(center.items.count == 3)
    }

    /// One agent answered: only its entry is read, not the other agents'
    /// entries on the same Moo pane.
    @Test func markingOneEntryReadLeavesTheOthers() {
        let center = AttentionCenter(integratesWithSystem: false)
        let surface = UUID()
        let first = center.record(TerminalNotification(title: "herdr: claude needs you", body: "api"),
                                  surfaceID: surface, location: "here", source: .herdr, repeatKey: "a")
        center.record(TerminalNotification(title: "herdr: codex needs you", body: "api"),
                      surfaceID: surface, location: "here", source: .herdr, repeatKey: "b")
        center.markRead(itemID: first.id)
        #expect(center.unreadCount == 1)
        #expect(center.items.first { $0.id == first.id }?.isRead == true)
    }
}
