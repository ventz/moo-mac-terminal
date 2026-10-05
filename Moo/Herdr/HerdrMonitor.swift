//
//  HerdrMonitor.swift
//  Moo
//
//  Settings → Notifications → herdr. When on, Moo looks for herdr clients
//  running in its own panes, reads each one's session over herdr's socket,
//  and shows that session's agents under the project whose tab runs the
//  client: in the sidebar, and as entries in the notification list.
//
//  herdr's agent status is inferred from the screen, not something the
//  program asked to say, so every entry this posts carries its own source
//  (`AttentionSource.herdr`) and says it came from herdr. Those entries do
//  drive the bell, Dock badge, tab dot and the project's "waiting" status,
//  as the approved design asks (2026-10-04): a blocked agent needs the user
//  as much as a program's own request does. That is the one exception to
//  AttentionCenter's "never inferred" rule, and it is labeled everywhere it
//  shows. Alerts are rate-limited per pane and per session.
//
//  Read-only throughout: HerdrBridge can only send the methods in
//  HerdrMethod, none of which types into a pane.
//

import AppKit
import Foundation
import Observation
import SwiftTerm

enum HerdrDefaults {
    static let showsAgents = "herdrShowsAgents"
    static let alertsWhenBlocked = "herdrAlertsWhenBlocked"
    static let alertsWhenFinished = "herdrAlertsWhenFinished"

    static let defaultShowsAgents = false
    static let defaultAlertsWhenBlocked = true
    /// Off: a finished turn happens on every prompt.
    static let defaultAlertsWhenFinished = false

    static var showsAgentsEnabled: Bool { bool(showsAgents, default: defaultShowsAgents) }
    static var blockedAlertsEnabled: Bool { bool(alertsWhenBlocked, default: defaultAlertsWhenBlocked) }
    static var finishedAlertsEnabled: Bool { bool(alertsWhenFinished, default: defaultAlertsWhenFinished) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// One herdr agent as the sidebar shows it.
struct HerdrAgentRow: Identifiable, Equatable {
    var id: String { "\(endpoint.socketPath)#\(paneID)" }
    let endpoint: HerdrEndpoint
    let paneID: String
    let agent: String
    let workspace: String
    let status: HerdrAgentStatus
    /// Finished a turn the user has not looked at yet.
    let isFinished: Bool
    /// No Moo pane runs a client for this session any more.
    let isDetached: Bool

    /// A detached session can be reattached from a new tab, unless it was
    /// named by a socket path a new shell would not resolve to.
    var canReattach: Bool { endpoint.attachCommand != nil }

    var statusText: String {
        if isDetached { return "detached" }
        if status == .blocked { return "needs you" }
        if isFinished { return "finished" }
        switch status {
        case .working: return "working"
        default: return "idle"
        }
    }
}

@Observable
@MainActor
final class HerdrMonitor {
    static let shared = HerdrMonitor()

    /// Bumped whenever rows change, so the sidebar redraws.
    private(set) var revision = 0
    /// `herdr --remote` clients seen in Moo panes. Their agents live on
    /// another machine and are not shown yet.
    private(set) var remoteHostCount = 0

    private struct Session {
        let bridge: HerdrBridge
        /// The Moo pane running a client for this session, while one does.
        var hostID: UUID?
        /// The project rows go under; kept after the client detaches.
        var projectID: UUID?
        var finishedPanes: Set<String> = []
        /// Unread entries this session posted, by herdr pane.
        var entries: [String: UUID] = [:]
        /// When each pane last alerted, and the session's recent alerts.
        var lastAlert: [String: Date] = [:]
        var recentAlerts: [Date] = []
        /// A reattach tab was opened; a second click waits for the next scan.
        var isReattaching = false
    }

    /// One alert per pane per this long, and at most `sessionAlertLimit`
    /// per session per minute: a flapping agent, or a hostile server, must
    /// not turn into a storm of banners, sounds and Dock bounces.
    static let paneAlertInterval: TimeInterval = 30
    static let sessionAlertLimit = 10

    @ObservationIgnored private var sessions: [HerdrEndpoint: Session] = [:]
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var isRunning = false

    // Seams for tests.
    @ObservationIgnored var attention: AttentionCenter = .shared
    @ObservationIgnored var scanHosts: () -> [UUID: HerdrClientKind] = HerdrMonitor.scanLiveHosts
    @ObservationIgnored var projectForHost: (UUID) -> UUID? = HerdrMonitor.projectOfController
    @ObservationIgnored var makeBridge: (HerdrEndpoint) -> HerdrBridge = { HerdrBridge(endpoint: $0) }
    @ObservationIgnored var isLookingAtHost: (UUID) -> Bool = HerdrMonitor.userIsLookingAt
    @ObservationIgnored var locationOfHost: (UUID) -> String = HerdrMonitor.locationOfController
    @ObservationIgnored var alertsWhenBlocked: () -> Bool = { HerdrDefaults.blockedAlertsEnabled }
    @ObservationIgnored var alertsWhenFinished: () -> Bool = { HerdrDefaults.finishedAlertsEnabled }
    @ObservationIgnored var now: () -> Date = Date.init

    static let scanInterval: TimeInterval = 2

    init() {}

    /// Follows the setting. Called at launch and whenever defaults change.
    func applySettings() {
        if HerdrDefaults.showsAgentsEnabled {
            start()
        } else {
            stop()
        }
    }

    func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        observers.append(center.addObserver(
            forName: .terminalFocusedPaneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteFocusChange() }
        })
        applySettings()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scan()
        let timer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        scanTimer?.invalidate()
        scanTimer = nil
        for endpoint in Array(sessions.keys) {
            endSession(endpoint)
        }
        remoteHostCount = 0
        changed()
    }

    // MARK: Rows

    func rows(for projectID: UUID) -> [HerdrAgentRow] {
        _ = revision
        var rows: [HerdrAgentRow] = []
        for (endpoint, session) in sessions where session.projectID == projectID {
            let bridge = session.bridge
            for pane in bridge.panes.values {
                guard let agent = pane.agent, pane.status != .unknown else { continue }
                // Cleaned on arrival, in HerdrBridge.
                rows.append(HerdrAgentRow(
                    endpoint: endpoint,
                    paneID: pane.paneID,
                    agent: agent,
                    workspace: bridge.workspaceLabels[pane.workspaceID] ?? "",
                    status: pane.status,
                    isFinished: session.finishedPanes.contains(pane.paneID),
                    isDetached: session.hostID == nil
                ))
            }
        }
        return rows.sorted {
            ($0.workspace, $0.agent, $0.paneID) < ($1.workspace, $1.agent, $1.paneID)
        }
    }

    /// Agents across every live session, for the Settings status line.
    var agentCount: Int {
        sessions.values.reduce(0) { total, session in
            total + session.bridge.panes.values.filter { $0.agent != nil && $0.status != .unknown }.count
        }
    }

    var liveSessionCount: Int {
        sessions.values.filter { $0.bridge.state == .live }.count
    }

    /// The first refusal, for Settings to explain.
    var refusal: String? {
        for session in sessions.values {
            if case .refused(let reason) = session.bridge.state { return reason }
        }
        return nil
    }

    // MARK: Going there

    /// Brings up the Moo pane running herdr and asks herdr to focus the
    /// agent's pane. A detached session gets a new tab that reattaches.
    func open(_ row: HerdrAgentRow) {
        guard var session = sessions[row.endpoint] else { return }
        session.finishedPanes.remove(row.paneID)
        sessions[row.endpoint] = session
        changed()
        if let hostID = session.hostID, let controller = Self.controller(for: hostID) {
            AttentionNavigator.reveal(controller)
            session.bridge.focus(paneID: row.paneID)
            return
        }
        guard let projectID = session.projectID else { return }
        let runtime = ProjectRuntime.shared
        runtime.select(projectID: projectID)
        guard let command = row.endpoint.attachCommand, !session.isReattaching else {
            NSSound.beep()
            return
        }
        sessions[row.endpoint]?.isReattaching = true
        let tab = runtime.session(for: projectID).addTab()
        tab.panes?.focusedController?.typeWhenStarted(command + "\n")
        runtime.invalidate()
    }

    /// The herdr pane an entry from the notification list came from.
    func focusPane(forEntry itemID: UUID) {
        for session in sessions.values {
            if let paneID = session.entries.first(where: { $0.value == itemID })?.key {
                session.bridge.focus(paneID: paneID)
                return
            }
        }
    }

    // MARK: Scanning

    func scan() {
        guard isRunning else { return }
        let before = sessions.mapValues { [$0.hostID?.uuidString, $0.projectID?.uuidString] }
        let remoteBefore = remoteHostCount
        let hosts = scanHosts()
        var byEndpoint: [HerdrEndpoint: [UUID]] = [:]
        var remote = 0
        for (controllerID, kind) in hosts {
            switch kind {
            case .local(let endpoint): byEndpoint[endpoint, default: []].append(controllerID)
            case .remote: remote += 1
            }
        }
        if remoteHostCount != remote { remoteHostCount = remote }

        for (endpoint, hostIDs) in byEndpoint {
            var session = sessions[endpoint] ?? {
                let bridge = makeBridge(endpoint)
                bridge.onChange = { [weak self] change in self?.bridgeChanged(endpoint, change) }
                bridge.start()
                return Session(bridge: bridge)
            }()
            if let current = session.hostID, hostIDs.contains(current) {
                // Keep the host the rows already sit under.
            } else {
                session.hostID = hostIDs.sorted { $0.uuidString < $1.uuidString }.first
            }
            if let hostID = session.hostID, let projectID = projectForHost(hostID) {
                session.projectID = projectID
            }
            session.isReattaching = false
            sessions[endpoint] = session
        }

        // Sessions with no client left in Moo stay listed, as detached,
        // while their server still answers.
        for endpoint in Array(sessions.keys) where byEndpoint[endpoint] == nil {
            guard var session = sessions[endpoint] else { continue }
            if session.hostID != nil {
                session.hostID = nil
                sessions[endpoint] = session
            }
            if session.bridge.state != .live && session.bridge.state != .connecting {
                endSession(endpoint)
            }
        }
        noteFocusChange()
        // Twice a second of sidebar redraws for nothing otherwise.
        let after = sessions.mapValues { [$0.hostID?.uuidString, $0.projectID?.uuidString] }
        if after != before || remoteHostCount != remoteBefore {
            changed()
        }
    }

    /// A finished mark has been seen once the user looks at the Moo pane
    /// running herdr while herdr shows that agent.
    func noteFocusChange() {
        var didChange = false
        for (endpoint, session) in sessions {
            guard let hostID = session.hostID, isLookingAtHost(hostID),
                  let focused = session.bridge.focusedPaneID,
                  session.finishedPanes.contains(focused) else { continue }
            sessions[endpoint]?.finishedPanes.remove(focused)
            didChange = true
        }
        if didChange { changed() }
    }

    private func endSession(_ endpoint: HerdrEndpoint) {
        guard let session = sessions.removeValue(forKey: endpoint) else { return }
        session.bridge.onChange = { _ in }
        session.bridge.stop()
        for itemID in session.entries.values {
            attention.markRead(itemID: itemID)
        }
    }

    // MARK: Alerts

    private func bridgeChanged(_ endpoint: HerdrEndpoint, _ change: HerdrBridgeChange) {
        guard case .status(let paneID, let agent, let from, let to) = change else {
            if let session = sessions[endpoint], session.bridge.state != .live, session.hostID == nil,
               session.bridge.state != .connecting {
                // A detached session whose server went away.
                endSession(endpoint)
            }
            noteFocusChange()
            changed()
            return
        }
        guard var session = sessions[endpoint] else { return }

        if from == .blocked, to != .blocked, let itemID = session.entries.removeValue(forKey: paneID) {
            // Answered, here or in herdr: the "needs you" no longer stands.
            attention.markRead(itemID: itemID)
        }
        let finished = from == .working && to.isAtRest
        if finished {
            session.finishedPanes.insert(paneID)
        } else if to == .working || to == .unknown {
            session.finishedPanes.remove(paneID)
        }
        sessions[endpoint] = session

        let name = Self.clean(agent ?? "agent")
        if to == .blocked, from != .blocked, alertsWhenBlocked() {
            post(endpoint, paneID: paneID, title: "herdr: \(name) needs you")
        } else if finished, alertsWhenFinished() {
            post(endpoint, paneID: paneID, title: "herdr: \(name) finished")
        }
        changed()
    }

    private func post(_ endpoint: HerdrEndpoint, paneID: String, title: String) {
        guard var session = sessions[endpoint], let hostID = session.hostID else { return }
        // Nothing to say when the user is looking at that very agent.
        if isLookingAtHost(hostID), session.bridge.focusedPaneID == paneID { return }

        let time = now()
        if let last = session.lastAlert[paneID], time.timeIntervalSince(last) < Self.paneAlertInterval {
            return
        }
        session.recentAlerts.removeAll { time.timeIntervalSince($0) >= 60 }
        guard session.recentAlerts.count < Self.sessionAlertLimit else { return }
        session.lastAlert[paneID] = time
        session.recentAlerts.append(time)

        let workspace = session.bridge.panes[paneID]
            .flatMap { session.bridge.workspaceLabels[$0.workspaceID] }
            .map(Self.clean) ?? ""
        let body = workspace.isEmpty ? "Detected by herdr" : "\(workspace) · detected by herdr"
        let item = attention.record(
            TerminalNotification(title: title, body: body),
            surfaceID: hostID,
            location: locationOfHost(hostID),
            source: .herdr,
            repeatKey: "\(endpoint.socketPath)#\(paneID)"
        )
        if let previous = session.entries[paneID], previous != item.id {
            // "needs you" replaces this agent's "finished": one entry each.
            attention.markRead(itemID: previous)
        }
        session.entries[paneID] = item.id
        sessions[endpoint] = session
    }

    private func changed() {
        revision &+= 1
    }

    /// herdr's names and labels are program-written text, cleaned like any
    /// other title before Moo shows them.
    static func clean(_ text: String) -> String {
        HerdrBridge.cleanName(text)
    }

    // MARK: Live lookups

    static func scanLiveHosts() -> [UUID: HerdrClientKind] {
        var hosts: [UUID: HerdrClientKind] = [:]
        for controller in ProjectRuntime.shared.allControllers {
            guard let process = controller.terminal?.process, process.running,
                  let kind = HerdrDiscovery.client(inForegroundOf: process.childfd) else { continue }
            hosts[controller.id] = kind
        }
        return hosts
    }

    static func controller(for id: UUID) -> TerminalSessionController? {
        ProjectRuntime.shared.allControllers.first { $0.id == id }
    }

    static func projectOfController(_ id: UUID) -> UUID? {
        controller(for: id).flatMap { ProjectRuntime.shared.location(of: $0)?.projectID }
    }

    static func userIsLookingAt(_ id: UUID) -> Bool {
        controller(for: id).map(AttentionCenter.isLookingAt) ?? false
    }

    static func locationOfController(_ id: UUID) -> String {
        controller(for: id).map(AttentionCenter.location(of:)) ?? "herdr"
    }
}
