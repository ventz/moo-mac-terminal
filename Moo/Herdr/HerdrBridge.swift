//
//  HerdrBridge.swift
//  Moo
//
//  Keeps a live copy of one herdr session's panes and agent statuses.
//
//  herdr's recipe for a client cache: subscribe first, then take a snapshot
//  and replace the cache with it, then apply events. Agent status can only
//  be subscribed to per pane (`pane.agent_status_changed` requires a
//  pane_id, and one unknown pane rejects the whole request), so the bridge
//  holds one long-lived connection for lifecycle events plus one per pane
//  that has an agent. Snapshots and focus requests use short connections:
//  herdr closes them after replying.
//
//  On `events_lost`, or when a connection drops, the bridge throws its
//  connections away and starts over, so a missed event can never leave a
//  stale status behind.
//
//  Every connection, not only the first, goes to the path the trust check
//  resolved and approved, and is checked again first.
//

import Foundation

nonisolated enum HerdrBridgeChange: Equatable, Sendable {
    case status(paneID: String, agent: String?, from: HerdrAgentStatus, to: HerdrAgentStatus)
    /// Panes, agents, labels or the connection changed shape.
    case structure
}

@MainActor
final class HerdrBridge {
    enum State: Equatable {
        case connecting
        case live
        /// No server answers at the socket; retrying with backoff.
        case unavailable(String)
        /// The socket failed the trust check. Not retried until restarted.
        case refused(String)
    }

    let endpoint: HerdrEndpoint
    private(set) var state: State = .connecting
    private(set) var panes: [String: HerdrPane] = [:]
    private(set) var workspaceLabels: [String: String] = [:]
    private(set) var focusedPaneID: String?
    private(set) var version: String?

    var onChange: (HerdrBridgeChange) -> Void = { _ in }

    /// Replaceable for tests.
    var trust: (String) -> HerdrDiscovery.Trust = { HerdrDiscovery.trust(socketPath: $0) }

    /// Per-pane status connections for one session, and across all of them:
    /// each is a file descriptor in Moo, and a GUI app has few to spare.
    static let paneConnectionLimit = 32
    static let globalPaneConnectionLimit = 64
    private(set) static var openPaneConnections = 0

    private var lifecycle: HerdrConnection?
    private var paneConnections: [String: HerdrConnection] = [:]
    /// The path the trust check resolved; every connection goes here.
    private var socketPath: String?
    /// Bumped on every restart, so callbacks from connections already thrown
    /// away are ignored.
    private var generation = 0
    private var retryDelay: TimeInterval = HerdrBridge.firstRetryDelay
    private var retryWork: DispatchWorkItem?
    private var isStopped = true
    private var snapshotPending = false

    static let firstRetryDelay: TimeInterval = 1
    static let longestRetryDelay: TimeInterval = 30
    static let snapshotDelay: TimeInterval = 0.1

    init(endpoint: HerdrEndpoint) {
        self.endpoint = endpoint
    }

    func start() {
        isStopped = false
        restart()
    }

    func stop() {
        isStopped = true
        generation &+= 1
        retryWork?.cancel()
        retryWork = nil
        closeConnections()
    }

    /// Asks herdr to focus a pane. Read-only in every other sense: focus
    /// moves no input.
    func focus(paneID: String) {
        guard state == .live, panes[paneID] != nil, let path = checkedPath() else { return }
        HerdrConnection.request(
            socketPath: path,
            HerdrProtocol.request(id: "focus", .paneFocus, params: ["pane_id": paneID])
        ) { _ in }
    }

    // MARK: Connecting

    private func restart() {
        guard !isStopped else { return }
        generation &+= 1
        retryWork?.cancel()
        retryWork = nil
        closeConnections()

        switch trust(endpoint.socketPath) {
        case .missing:
            fail(.unavailable("No herdr server is running for this session."))
            return
        case .refused(let reason):
            socketPath = nil
            setState(.refused(Self.clean(reason)))
            clearPanes()
            return
        case .trusted(let resolved):
            socketPath = resolved
        }

        setState(.connecting)
        let current = generation
        let connection = HerdrConnection(
            socketPath: socketPath ?? endpoint.socketPath,
            label: "lifecycle",
            onLine: { [weak self] line in
                guard let self, self.generation == current else { return }
                self.handleLifecycle(line)
            },
            onEnd: { [weak self] end in
                guard let self, self.generation == current else { return }
                self.fail(.unavailable(Self.describe(end)))
            }
        )
        lifecycle = connection
        connection.send(HerdrProtocol.subscribe(id: "lifecycle", to: HerdrProtocol.lifecycleSubscriptions))
    }

    /// The approved path, if the socket still passes the check and still
    /// resolves to it. A socket that changed underneath fails the session.
    private func checkedPath() -> String? {
        guard let approved = socketPath else { return nil }
        if case .trusted(let resolved) = trust(endpoint.socketPath), resolved == approved {
            return approved
        }
        socketPath = nil
        fail(.unavailable("The herdr socket changed."))
        return nil
    }

    private func handleLifecycle(_ line: Data) {
        switch HerdrProtocol.parse(line) {
        case .response(_, let type) where type == "subscription_started":
            requestSnapshot()
        case .error(_, let code, let message):
            if code == "events_lost" {
                restart()
            } else {
                fail(.unavailable(message.isEmpty ? code : message))
            }
        case .event(let event):
            apply(event)
        default:
            break
        }
    }

    private func requestSnapshot() {
        guard let path = checkedPath() else { return }
        let current = generation
        HerdrConnection.request(
            socketPath: path,
            HerdrProtocol.request(id: "snapshot", .snapshot)
        ) { [weak self] reply in
            guard let self, self.generation == current else { return }
            guard let reply, case .snapshot(_, let snapshot)? = HerdrProtocol.parse(reply) else {
                self.fail(.unavailable("herdr did not answer with a snapshot."))
                return
            }
            self.apply(snapshot)
        }
    }

    /// One snapshot for any number of reasons arriving together: new pane
    /// subscriptions landing right after a snapshot of a busy session, or a
    /// burst of panes in workspaces not seen yet.
    private func scheduleSnapshot() {
        guard !snapshotPending else { return }
        snapshotPending = true
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotPending = false
                guard self.generation == current, self.state == .live else { return }
                self.requestSnapshot()
            }
        }
    }

    private func fail(_ state: State) {
        retryWork?.cancel()
        retryWork = nil
        generation &+= 1
        closeConnections()
        clearPanes()
        setState(Self.cleaned(state))
        guard !isStopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.longestRetryDelay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeConnections() {
        lifecycle?.cancel()
        lifecycle = nil
        for paneID in Array(paneConnections.keys) {
            closePaneConnection(paneID)
        }
        snapshotPending = false
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onChange(.structure)
    }

    /// Forgets the session. Each status that was known is reported as gone,
    /// so whatever was built on it (a "needs you" entry, a finished mark)
    /// is cleared rather than left to outlive the connection.
    private func clearPanes() {
        guard !panes.isEmpty || !workspaceLabels.isEmpty else { return }
        let old = panes
        panes.removeAll()
        workspaceLabels.removeAll()
        focusedPaneID = nil
        for pane in old.values.sorted(by: { $0.paneID < $1.paneID }) where pane.status != .unknown {
            onChange(.status(paneID: pane.paneID, agent: pane.agent, from: pane.status, to: .unknown))
        }
        onChange(.structure)
    }

    // MARK: Applying

    /// Replaces the cache with a snapshot. A status that differs from the
    /// cached one is reported as a change, so a transition that happened
    /// while events were lost is still seen.
    private func apply(_ snapshot: HerdrSnapshot) {
        let old = panes
        panes = Dictionary(snapshot.panes.map { ($0.paneID, Self.cleaned($0)) }, uniquingKeysWith: { _, last in last })
        workspaceLabels = snapshot.workspaceLabels.mapValues(Self.cleanName)
        focusedPaneID = snapshot.focusedPaneID
        version = snapshot.version
        retryDelay = Self.firstRetryDelay

        for paneID in Array(paneConnections.keys) where panes[paneID]?.agent == nil {
            closePaneConnection(paneID)
        }
        for pane in panes.values.sorted(by: { $0.paneID < $1.paneID }) where pane.agent != nil {
            subscribeStatus(paneID: pane.paneID)
        }
        // The socket failed its re-check while subscribing.
        guard socketPath != nil else { return }
        setState(.live)
        for pane in panes.values.sorted(by: { $0.paneID < $1.paneID }) {
            let previous = old[pane.paneID]?.status ?? .unknown
            if previous != pane.status {
                onChange(.status(paneID: pane.paneID, agent: pane.agent, from: previous, to: pane.status))
            }
        }
        onChange(.structure)
    }

    private func apply(_ event: HerdrEvent) {
        switch event {
        case .paneCreated(let created):
            guard panes.count < HerdrProtocol.paneLimit else { return }
            let pane = Self.cleaned(created)
            panes[pane.paneID] = pane
            if pane.agent != nil {
                subscribeStatus(paneID: pane.paneID)
            }
            if workspaceLabels[pane.workspaceID] == nil {
                scheduleSnapshot()
            }
            onChange(.structure)
        case .paneClosed(let paneID):
            closePaneConnection(paneID)
            guard let removed = panes.removeValue(forKey: paneID) else { return }
            if removed.status != .unknown {
                onChange(.status(paneID: paneID, agent: removed.agent, from: removed.status, to: .unknown))
            }
            onChange(.structure)
        case .paneFocused(let paneID):
            guard focusedPaneID != paneID else { return }
            focusedPaneID = paneID
            onChange(.structure)
        case .agentDetected(let paneID, let agent, let released):
            guard var pane = panes[paneID] else { return }
            if released {
                let previous = pane.status
                pane.agent = nil
                pane.status = .unknown
                panes[paneID] = pane
                closePaneConnection(paneID)
                if previous != .unknown {
                    onChange(.status(paneID: paneID, agent: agent, from: previous, to: .unknown))
                }
            } else {
                pane.agent = agent.map(Self.cleanName) ?? pane.agent ?? "agent"
                panes[paneID] = pane
                // Status events only come on the pane's own subscription.
                subscribeStatus(paneID: paneID)
            }
            onChange(.structure)
        case .statusChanged(let paneID, let agent, let status):
            guard var pane = panes[paneID] else { return }
            let previous = pane.status
            pane.agent = agent.map(Self.cleanName) ?? pane.agent
            pane.status = status
            panes[paneID] = pane
            if previous != status {
                onChange(.status(paneID: paneID, agent: pane.agent, from: previous, to: status))
            }
            onChange(.structure)
        case .workspacesChanged:
            scheduleSnapshot()
        case .other:
            break
        }
    }

    private func subscribeStatus(paneID: String) {
        guard paneConnections[paneID] == nil,
              paneConnections.count < Self.paneConnectionLimit,
              Self.openPaneConnections < Self.globalPaneConnectionLimit,
              let path = checkedPath() else { return }
        let current = generation
        let connection = HerdrConnection(
            socketPath: path,
            label: "pane",
            onLine: { [weak self] line in
                guard let self, self.generation == current else { return }
                self.handlePaneLine(line, paneID: paneID)
            },
            onEnd: { [weak self] _ in
                guard let self, self.generation == current else { return }
                // The pane closed, or the server went away; the lifecycle
                // connection reports the second.
                self.closePaneConnection(paneID)
            }
        )
        paneConnections[paneID] = connection
        Self.openPaneConnections += 1
        connection.send(HerdrProtocol.subscribe(id: "pane", to: HerdrProtocol.statusSubscription(paneID: paneID)))
    }

    private func closePaneConnection(_ paneID: String) {
        guard let connection = paneConnections.removeValue(forKey: paneID) else { return }
        connection.cancel()
        Self.openPaneConnections = max(0, Self.openPaneConnections - 1)
    }

    private func handlePaneLine(_ line: Data, paneID: String) {
        switch HerdrProtocol.parse(line) {
        case .response(_, let type) where type == "subscription_started":
            // A status that changed between the snapshot and this
            // subscription would otherwise never be seen.
            scheduleSnapshot()
        case .event(let event):
            apply(event)
        case .error(_, "events_lost", _):
            restart()
        case .error:
            // pane_not_found: it closed before the subscription landed.
            closePaneConnection(paneID)
        default:
            break
        }
    }

    private static func describe(_ end: HerdrConnectionEnd) -> String {
        switch end {
        case .closed: return "The herdr server closed the connection."
        case .lineTooLong: return "herdr sent a line longer than Moo accepts."
        case .failed(let reason): return reason
        }
    }

    /// Reasons can carry herdr's own words or a path from another process's
    /// environment; they are cleaned before anything can show them.
    private static func clean(_ text: String) -> String {
        TerminalNotificationParser.clean(text, limit: TerminalNotificationParser.bodyLimit)
    }

    /// Agent names and workspace labels are program-written text: cleaned
    /// once, here, as they arrive, like any terminal title.
    static func cleanName(_ text: String) -> String {
        TerminalNotificationParser.clean(text, limit: 60)
    }

    private static func cleaned(_ pane: HerdrPane) -> HerdrPane {
        var pane = pane
        pane.agent = pane.agent.map(cleanName)
        return pane
    }

    private static func cleaned(_ state: State) -> State {
        switch state {
        case .unavailable(let reason): return .unavailable(clean(reason))
        case .refused(let reason): return .refused(clean(reason))
        default: return state
        }
    }
}
