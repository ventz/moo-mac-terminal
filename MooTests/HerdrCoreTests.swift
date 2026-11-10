//
//  HerdrCoreTests.swift
//  MooTests
//
//  herdr-core (the Herdr app's daemon): its protocol, finding its sockets,
//  the bridge against a fake core, the agent panel's rows, and the theme
//  colors the panel takes.
//

import Foundation
import SwiftUI
import Testing
@testable import Moo

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

private func line(_ text: String) -> Data { Data(text.utf8) }

// MARK: - Protocol

struct HerdrCoreProtocolTests {
    /// The same socket can start programs and type into terminals: Moo may
    /// only subscribe.
    @Test func onlyTheSubscriptionExists() {
        #expect(HerdrCoreMethod.allCases.map(\.rawValue) == ["events.subscribe"])
    }

    @Test func subscribeIsAJSONRPCLine() throws {
        let request = HerdrCoreProtocol.subscribe(id: 1)
        #expect(request.data.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: request.data.dropLast()) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 1)
        #expect(object["method"] as? String == "events.subscribe")
    }

    /// Shapes as herdr-core 0.1.19 sends them.
    @Test func parsesTheSnapshot() throws {
        let reply = """
            {"id":1,"jsonrpc":"2.0","result":{"channel":null,"seq":604,"terminals":[\
            {"address":"t1","argv":["/bin/zsh","-l"],"cwd":"/w","foreground":{"argv":["claude"],"cwd":"/w/api","name":"2.1.3","pid":4},\
            "labels":{"herdr.space":"sp1","herdr.tab":"tb1","where":"api / 1"},"state":"live",\
            "status":{"app":"claude-code","state":"blocked","kind":"permission","msg":"Run tests?","progress":40},"title":"Fix the build"},\
            {"address":"t2","cwd":"/w","foreground":{"name":"zsh","cwd":"/w/web"},"labels":{},"state":"live","status":null,"title":""},\
            {"address":"t3","cwd":"/w","labels":{},"state":"finished","status":{"state":"done"}}]}}
            """
        guard case .snapshot(let seq, let terminals)? = HerdrCoreProtocol.parse(line(reply)) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(seq == 604)
        // Finished terminals are not listed.
        #expect(terminals.map(\.address) == ["t1", "t2"])
        let agent = try #require(terminals[0].agent)
        #expect(agent.agent == "claude-code")
        #expect(agent.status == .blocked)
        #expect(agent.blockedKind == "permission")
        #expect(agent.message == "Run tests?")
        #expect(agent.location == "api")
        #expect(agent.title == "Fix the build")
        // No status: not an agent, but kept for when it reports one.
        #expect(terminals[1].agent == nil)
        #expect(terminals[1].cwd == "/w/web")
        #expect(terminals[1].foregroundName == "zsh")
        // argv[0], not the process title Claude Code sets to its version.
        #expect(terminals[0].foregroundName == "claude")
    }

    @Test func parsesEvents() {
        func event(_ type: String, _ data: String, seq: Int = 9) -> HerdrCoreMessage? {
            HerdrCoreProtocol.parse(line(
                #"{"jsonrpc":"2.0","method":"event","params":{"data":\#(data),"seq":\#(seq),"terminal":"t5","type":"\#(type)"}}"#
            ))
        }
        #expect(event("status", #"{"records":{},"reported":true,"status":{"app":"codex","state":"working"}}"#)
                == .event(.status(seq: 9, address: "t5", status: ["app": "codex", "state": "working"])))
        #expect(event("status", #"{"records":{},"reported":true,"status":null}"#)
                == .event(.status(seq: 9, address: "t5", status: nil)))
        #expect(event("labels", #"{"labels":{"where":"web / 2"}}"#)
                == .event(.labels(seq: 9, address: "t5", labels: ["where": "web / 2"])))
        #expect(event("title", #"{"title":"Refactor"}"#) == .event(.title(seq: 9, address: "t5", title: "Refactor")))
        #expect(event("foreground", #"{"argv":["sh"],"cwd":"/tmp","name":"bash","pid":3}"#)
                == .event(.foreground(seq: 9, address: "t5", name: "sh", cwd: "/tmp")))
        for gone in ["finished", "lost", "removed"] {
            #expect(event(gone, "{}") == .event(.gone(seq: 9, address: "t5")))
        }
        #expect(event("size", #"{"cols":80,"rows":24}"#) == .event(.other(seq: 9)))
        if case .event(.upserted(_, let raw))? = event("created", #"{"address":"t5","state":"live","labels":{},"cwd":"/tmp/x","status":null}"#) {
            #expect(raw.address == "t5")
            #expect(raw.cwd == "/tmp/x")
        } else {
            Issue.record("created not parsed")
        }

        #expect(HerdrCoreProtocol.parse(line(#"{"jsonrpc":"2.0","method":"missed","params":{}}"#)) == .missed)
        #expect(HerdrCoreProtocol.parse(line(#"{"jsonrpc":"2.0","method":"heartbeat","params":{}}"#)) == .heartbeat)
        #expect(HerdrCoreProtocol.parse(line(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"the core is stopping","data":{"kind":"unavailable"}}}"#
        )) == .error(kind: "unavailable", message: "the core is stopping"))
        #expect(HerdrCoreProtocol.parse(line("not json")) == nil)
    }

    @Test func groupsByTheHerdrSpaceThenTheFolder() {
        #expect(HerdrCoreProtocol.location(labels: ["where": "moo / 1"], cwd: "/x/y") == "moo")
        #expect(HerdrCoreProtocol.location(labels: [:], cwd: "/x/project") == "project")
        #expect(HerdrCoreProtocol.location(labels: [:], cwd: "/") == "herdr")
    }

    /// An address is typed into a shell: only `t7` or `machine/t7`.
    @Test func onlyPlainAddressesAreAttached() {
        let endpoint = HerdrCoreEndpoint(socketPath: "/s", sessionName: nil)
        // The default session is named too, so an exported HC_SESSION
        // cannot send the click to another session's t7.
        #expect(endpoint.attachCommand(address: "t7", observe: false) == "HC_SESSION=default hc attach t7")
        #expect(endpoint.attachCommand(address: "box/t12", observe: true) == "HC_SESSION=default hc attach --observe box/t12")
        for bad in ["t", "7", "t7;rm", "t7 x", "-t7", "a/b/t7", "../t7", "t7\n", "tx"] {
            #expect(endpoint.attachCommand(address: bad, observe: false) == nil, "\(bad)")
        }
        let named = HerdrCoreEndpoint(socketPath: "/s", sessionName: "work")
        #expect(named.attachCommand(address: "t1", observe: false) == "HC_SESSION=work hc attach t1")
    }
}

// MARK: - Discovery

struct HerdrCoreDiscoveryTests {
    @Test func findsEverySessionSocketInTheStateFolder() throws {
        let state = (NSTemporaryDirectory() as NSString).appendingPathComponent("hs.\(UUID().uuidString.prefix(6))")
        let root = (state as NSString).appendingPathComponent("herdr-core")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        let main = try FakeHerdrCoreServer(sessionName: "default", root: root)
        let work = try FakeHerdrCoreServer(sessionName: "work", root: root)
        // A folder with no socket, and a socket-shaped file that is not one.
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        let fake = (root as NSString).appendingPathComponent("plain")
        try FileManager.default.createDirectory(atPath: fake, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (fake as NSString).appendingPathComponent("plain.sock"), contents: Data())

        let found = HerdrCoreDiscovery.endpoints(environment: ["XDG_STATE_HOME": state], home: "/nonexistent")
        #expect(found == [
            HerdrCoreEndpoint(socketPath: main.socketPath, sessionName: nil),
            HerdrCoreEndpoint(socketPath: work.socketPath, sessionName: "work"),
        ])
        #expect(HerdrCoreDiscovery.endpoints(environment: [:], home: "/nonexistent").isEmpty)
        // ~/.local/state is looked in whatever Moo's own environment says.
        let home = (state as NSString).appendingPathComponent("home")
        let homeState = (home as NSString).appendingPathComponent(".local/state/herdr-core")
        try FileManager.default.createDirectory(atPath: homeState, withIntermediateDirectories: true)
        let other = try FakeHerdrCoreServer(sessionName: "other", root: homeState)
        let both = HerdrCoreDiscovery.endpoints(environment: ["XDG_STATE_HOME": state], home: home)
        #expect(both.map(\.sessionName) == [nil, "work", "other"])
        #expect(both.last?.socketPath == other.socketPath)
    }
}

// MARK: - Bridge

@MainActor
struct HerdrCoreBridgeTests {
    func bridge(for server: FakeHerdrCoreServer) -> (HerdrCoreBridge, () -> [HerdrBridgeChange]) {
        let bridge = HerdrCoreBridge(endpoint: HerdrCoreEndpoint(socketPath: server.socketPath, sessionName: nil))
        var changes: [HerdrBridgeChange] = []
        bridge.onChange = { changes.append($0) }
        return (bridge, { changes.filter { if case .status = $0 { return true } else { return false } } })
    }

    @Test func loadsTheSnapshotThenFollowsStatus() async throws {
        let server = try FakeHerdrCoreServer(terminals: [
            FakeHerdrCoreServer.terminal("t1", state: "working"),
            FakeHerdrCoreServer.terminal("t2"),
        ])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        #expect(Set(bridge.agents.keys) == ["t1"])
        #expect(server.methods == ["events.subscribe"])

        server.pushStatus("t1", "blocked")
        server.pushStatus("t2", "working", app: "codex")
        try await waitUntil("t2 working") { bridge.agents["t2"]?.status == .working }
        #expect(bridge.agents["t1"]?.status == .blocked)
        #expect(bridge.agents["t2"]?.agent == "codex")
        #expect(statuses() == [
            .status(paneID: "t1", agent: "claude-code", from: .unknown, to: .working),
            .status(paneID: "t1", agent: "claude-code", from: .working, to: .blocked),
            .status(paneID: "t2", agent: "codex", from: .unknown, to: .working),
        ])

        // The program stops reporting, then the terminal goes away.
        server.pushStatus("t2", nil)
        try await waitUntil("t2 quiet") { bridge.agents["t2"] == nil }
        server.push("removed", terminal: "t1")
        try await waitUntil("t1 gone") { bridge.agents.isEmpty }
        #expect(statuses().last == .status(paneID: "t1", agent: "claude-code", from: .blocked, to: .unknown))
    }

    @Test func followsNewTerminalsAndLabels() async throws {
        let server = try FakeHerdrCoreServer()
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }

        server.push("created", terminal: "t9", data: FakeHerdrCoreServer.terminal("t9", state: "idle", place: "web / 1"))
        try await waitUntil("t9") { bridge.agents["t9"] != nil }
        #expect(bridge.agents["t9"]?.location == "web")
        server.push("labels", terminal: "t9", data: ["labels": ["where": "docs / 2"]])
        try await waitUntil("moved") { bridge.agents["t9"]?.location == "docs" }
    }

    /// An event at or below the sequence already applied changes nothing.
    @Test func ignoresStaleEvents() async throws {
        let server = try FakeHerdrCoreServer(terminals: [FakeHerdrCoreServer.terminal("t1", state: "idle")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        server.pushStale("t1", "working")
        server.pushStatus("t1", "done")
        try await waitUntil("done") { bridge.agents["t1"]?.status == .done }
        #expect(bridge.agents["t1"]?.status == .done)
    }

    /// A subscriber that fell behind starts over, and a change it missed is
    /// still reported.
    @Test func missedResubscribes() async throws {
        let server = try FakeHerdrCoreServer(terminals: [FakeHerdrCoreServer.terminal("t1", state: "working")])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }

        server.terminals = [FakeHerdrCoreServer.terminal("t1", state: "blocked")]
        server.pushMissed()
        try await waitUntil("resubscribed") { server.subscriptionCount == 2 && bridge.agents["t1"]?.status == .blocked }
        #expect(bridge.state == .live)
        #expect(statuses().last == .status(paneID: "t1", agent: "claude-code", from: .working, to: .blocked))
    }

    @Test func aHangUpClearsAgentsAndRetries() async throws {
        let server = try FakeHerdrCoreServer(terminals: [FakeHerdrCoreServer.terminal("t1", state: "working")])
        let (bridge, statuses) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        server.hangUpSubscribers()
        try await waitUntil("cleared") { bridge.agents.isEmpty }
        #expect(statuses().last == .status(paneID: "t1", agent: "claude-code", from: .working, to: .unknown))
        try await waitUntil("back") { bridge.state == .live && bridge.agents["t1"] != nil }
    }

    /// A core that stops answering, heartbeats included, is not trusted to
    /// still be right.
    @Test func silenceCountsAsGone() async throws {
        let server = try FakeHerdrCoreServer(terminals: [FakeHerdrCoreServer.terminal("t1", state: "working")])
        let (bridge, _) = bridge(for: server)
        bridge.silenceLimit = 0.3
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        try await waitUntil("given up") {
            if case .unavailable = bridge.state { return true }
            return false
        }
        #expect(bridge.agents.isEmpty)
    }

    @Test func refusesAnUntrustedSocket() async throws {
        let server = try FakeHerdrCoreServer()
        let (bridge, _) = bridge(for: server)
        bridge.trust = { _ in .refused("not yours") }
        bridge.start()
        defer { bridge.stop() }
        #expect(bridge.state == .refused("not yours"))
        #expect(server.methods.isEmpty)
    }

    /// A core that keeps saying the subscriber fell behind is backed off
    /// from rather than resubscribed to in a loop.
    @Test func repeatedMissedBacksOff() async throws {
        let server = try FakeHerdrCoreServer(terminals: [FakeHerdrCoreServer.terminal("t1", state: "working")])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        server.pushMissed()
        try await waitUntil("resubscribed") { server.subscriptionCount == 2 && bridge.state == .live }
        server.pushMissed()
        try await waitUntil("backed off") {
            if case .unavailable = bridge.state { return true }
            return false
        }
        #expect(server.subscriptionCount == 2)
    }

    /// Titles and the folders of plain shells change all the time; only a
    /// change to what the panel lists redraws it.
    @Test func onlyListingChangesRedraw() async throws {
        let server = try FakeHerdrCoreServer(terminals: [
            FakeHerdrCoreServer.terminal("t1", state: "working"),
            FakeHerdrCoreServer.terminal("t2"),
        ])
        let bridge = HerdrCoreBridge(endpoint: HerdrCoreEndpoint(socketPath: server.socketPath, sessionName: nil))
        var structures = 0
        bridge.onChange = { if case .structure = $0 { structures += 1 } }
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        let before = structures
        server.push("title", terminal: "t1", data: ["title": "Thinking…"])
        server.push("foreground", terminal: "t2", data: ["argv": ["vim"], "cwd": "/tmp/x", "name": "vim", "pid": 2])
        server.push("labels", terminal: "t1", data: ["labels": ["where": "docs / 1"]])
        try await waitUntil("moved") { bridge.agents["t1"]?.location == "docs" }
        #expect(bridge.agents["t1"]?.title == "Thinking…")
        #expect(structures == before + 1)
    }

    /// Program-written text is cleaned before anything can show it.
    @Test func cleansProgramText() async throws {
        let server = try FakeHerdrCoreServer(terminals: [
            FakeHerdrCoreServer.terminal("t1", state: "working", app: "evil\u{1b}[2Jname", place: "sp\u{07}ace / 1"),
        ])
        let (bridge, _) = bridge(for: server)
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil("live") { bridge.state == .live }
        let agent = try #require(bridge.agents["t1"])
        #expect(!agent.agent.contains("\u{1b}"))
        #expect(!agent.location.contains("\u{07}"))
        // Events are cleaned too, not only the snapshot.
        server.push("labels", terminal: "t1", data: ["labels": ["where": "bad\u{1b}]0;x\u{07} / 1"]])
        try await waitUntil("relabeled") { bridge.agents["t1"]?.location.hasPrefix("bad") == true }
        #expect(bridge.agents["t1"]?.location.contains("\u{1b}") == false)
        #expect(bridge.agents["t1"]?.location.contains("\u{07}") == false)
    }
}

// MARK: - Panel

@MainActor
struct HerdrAgentPanelTests {
    @Test func listsHerdrCoreAgentsGroupedBySpace() async throws {
        let server = try FakeHerdrCoreServer(terminals: [
            FakeHerdrCoreServer.terminal("t1", state: "working", app: "codex", place: "web / 1"),
            FakeHerdrCoreServer.terminal("t2", state: "blocked", kind: "permission", place: "api / 1"),
            FakeHerdrCoreServer.terminal("t3", state: "done", place: "api / 2"),
            FakeHerdrCoreServer.terminal("t4"),
        ])
        let endpoint = HerdrCoreEndpoint(socketPath: server.socketPath, sessionName: nil)
        let monitor = HerdrMonitor()
        monitor.attention = AttentionCenter(integratesWithSystem: false)
        monitor.scanHosts = { [:] }
        monitor.scanCoreEndpoints = { [endpoint] }
        monitor.start()
        defer { monitor.stop() }

        try await waitUntil("rows") { monitor.panelRows.count == 3 }
        let rows = monitor.panelRows
        #expect(rows.map(\.group) == ["api", "api", "web"])
        #expect(rows.map(\.agent) == ["claude-code", "claude-code", "codex"])
        #expect(rows.map(\.statusText) == ["needs you: permission", "finished", "working"])
        #expect(monitor.coreAgentCount == 3)
        #expect(monitor.liveCoreSessionCount == 1)
        // Nothing posted: there is no Moo pane to point an entry at.
        #expect(monitor.attention.items.isEmpty)

        monitor.stop()
        #expect(monitor.panelRows.isEmpty)
    }

    /// The dragged height stays between the minimum and what leaves the
    /// projects their share of the sidebar.
    @Test func panelHeightIsClamped() {
        #expect(AgentPanelView.clampedListHeight(300, sidebarHeight: 800) == 300)
        #expect(AgentPanelView.clampedListHeight(10, sidebarHeight: 800) == AgentPanelView.minimumListHeight)
        #expect(AgentPanelView.clampedListHeight(900, sidebarHeight: 800) == 800 - AgentPanelView.projectsReserve)
        #expect(AgentPanelView.clampedListHeight(300, sidebarHeight: 100) == AgentPanelView.minimumListHeight)
        // Not measured yet: no upper clamp.
        #expect(AgentPanelView.clampedListHeight(500, sidebarHeight: 0) == 500)
    }

    @Test func panelRowsFromHerdrSessionsKeepTheirDetails() {
        let endpoint = HerdrEndpoint(socketPath: "/s", sessionName: nil)
        let row = HerdrAgentRow(endpoint: endpoint, paneID: "w1:p1", agent: "claude", workspace: "",
                                status: .idle, isFinished: true, isDetached: false)
        let panel = HerdrPanelRow(source: .session(row))
        #expect(panel.group == "herdr")
        #expect(panel.status == .done)
        #expect(panel.statusText == "finished")
        #expect(panel.id == row.id)
    }
}

// MARK: - Theme

@MainActor
struct AgentPanelThemeTests {
    let legacy = """
        {"name":"Old","ansi":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777",
        "#888888","#999999","#aaaaaa","#bbbbbb","#cccccc","#dddddd","#eeeeee","#ffffff"],
        "foreground":"#ffffff","background":"#000000"}
        """

    /// Themes written before the panel existed load as they did, and are
    /// written back without the new key.
    @Test func legacyThemesAreUnchanged() throws {
        let theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(legacy.utf8))
        #expect(theme.agentPanel == nil)
        let written = String(decoding: try JSONEncoder().encode(theme), as: UTF8.self)
        #expect(!written.contains("agentPanel"))
    }

    @Test func panelColorsRoundTrip() throws {
        let json = legacy.replacingOccurrences(
            of: ##""background":"#000000"}"##,
            with: ##""background":"#000000","agentPanel":{"working":"#00ff00","blocked":"#ff0000","text":"#eeeeee"}}"##
        )
        let theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(json.utf8))
        let panel = try #require(theme.agentPanel)
        #expect(panel.working == ProfileColor(hex: "#00ff00"))
        #expect(panel.blocked == ProfileColor(hex: "#ff0000"))
        #expect(panel.text == ProfileColor(hex: "#eeeeee"))
        #expect(panel.idle == nil)
        let again = try JSONDecoder().decode(TerminalTheme.self, from: JSONEncoder().encode(theme))
        #expect(again == theme)
        #expect(AgentPanelColors().isEmpty)
        #expect(!panel.isEmpty)
    }

    @Test func styleTakesThemeColorsOnlyInAThemedWindow() throws {
        var theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(legacy.utf8))
        theme.agentPanel = AgentPanelColors(working: ProfileColor(hex: "#00ff00"))
        let themed = AgentPanelStyle(theme: theme, themed: true)
        #expect(themed.working == ProfileColor(hex: "#00ff00")!.swiftUIColor)
        #expect(themed.blocked == AgentPanelStyle.standard.blocked)
        #expect(themed.color(for: .working) == themed.working)
        #expect(themed.color(for: .unknown) == themed.idle)
        #expect(AgentPanelStyle(theme: theme, themed: false) == .standard)
        #expect(AgentPanelStyle(theme: nil, themed: true) == .standard)
    }
}
