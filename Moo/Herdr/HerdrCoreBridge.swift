//
//  HerdrCoreBridge.swift
//  Moo
//
//  Keeps a live copy of one herdr-core session's agents.
//
//  herdr-core makes this simpler than herdr 0.9: one `events.subscribe`
//  answers with every terminal and a sequence number, then carries every
//  change on the same connection, statuses included, with a heartbeat every
//  15 seconds. A subscriber that falls behind is told (`missed`), and the
//  bridge starts over, so a lost event can never leave a stale status.
//  Events at or below the sequence number already applied are ignored.
//
//  A connection that goes quiet for longer than three heartbeats is treated
//  as gone: a core that hangs must not leave its agents listed as working.
//  One that never answers the subscription is given up on too.
//
//  The sidebar redraws only when an agent's listing changes: titles, folders
//  and labels of terminals that are not agents arrive constantly (a prompt
//  that sets the title, every `cd`) and change nothing it shows.
//
//  Like HerdrBridge, every connection goes to the path the trust check
//  resolved and approved.
//

import Foundation

@MainActor
final class HerdrCoreBridge {
    typealias State = HerdrBridge.State

    let endpoint: HerdrCoreEndpoint
    private(set) var state: State = .connecting
    /// Every live terminal on the core, agents or not, by address.
    private(set) var terminals: [String: HerdrCoreRaw] = [:]

    var onChange: (HerdrBridgeChange) -> Void = { _ in }

    /// Replaceable for tests.
    var trust: (String) -> HerdrDiscovery.Trust = { HerdrDiscovery.trust(socketPath: $0) }
    var silenceLimit: TimeInterval = 45

    private var connection: HerdrConnection?
    private var seq: UInt64 = 0
    private var generation = 0
    private var retryDelay: TimeInterval = HerdrBridge.firstRetryDelay
    private var retryWork: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?
    private var isStopped = true
    /// When the connection last went live, and when the core last said this
    /// subscriber fell behind: a core that keeps doing either is retried
    /// with backoff rather than in a loop.
    private var liveSince: Date?
    private var lastMissed: Date?
    var now: () -> Date = Date.init
    /// How long a connection must stay live before its backoff resets.
    static let stableInterval: TimeInterval = 30

    init(endpoint: HerdrCoreEndpoint) {
        self.endpoint = endpoint
    }

    /// The terminals reporting a status, by address.
    var agents: [String: HerdrCoreTerminal] {
        var agents: [String: HerdrCoreTerminal] = [:]
        for raw in terminals.values {
            if let agent = raw.agent { agents[raw.address] = agent }
        }
        return agents
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
        watchdog?.cancel()
        watchdog = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: Connecting

    private func restart() {
        guard !isStopped else { return }
        generation &+= 1
        retryWork?.cancel()
        retryWork = nil
        connection?.cancel()
        connection = nil

        let path: String
        switch trust(endpoint.socketPath) {
        case .missing:
            fail(.unavailable("No herdr-core is running for this session."))
            return
        case .refused(let reason):
            setState(.refused(HerdrBridge.cleanName(reason)))
            clearTerminals()
            return
        case .trusted(let resolved):
            path = resolved
        }

        if state != .live { setState(.connecting) }
        let current = generation
        let connection = HerdrConnection(
            socketPath: path,
            label: "core",
            onLine: { [weak self] line in
                guard let self, self.generation == current else { return }
                self.handle(line)
            },
            onEnd: { [weak self] end in
                guard let self, self.generation == current else { return }
                switch end {
                case .closed: self.fail(.unavailable("herdr-core closed the connection."))
                case .lineTooLong: self.fail(.unavailable("herdr-core sent a line longer than Moo accepts."))
                case .failed(let reason): self.fail(.unavailable(reason))
                }
            }
        )
        self.connection = connection
        connection.send(HerdrCoreProtocol.subscribe(id: 1))
        armWatchdog()
    }

    private func handle(_ line: Data) {
        // Until the snapshot arrives, heartbeats do not count as an answer.
        if state == .live { armWatchdog() }
        switch HerdrCoreProtocol.parse(line) {
        case .snapshot(let seq, let terminals):
            apply(snapshot: terminals, seq: seq)
        case .event(let event):
            guard state == .live, event.seq > seq else { return }
            seq = event.seq
            apply(event)
        case .missed:
            if let lastMissed, now().timeIntervalSince(lastMissed) < Self.stableInterval {
                fail(.unavailable("Moo keeps falling behind herdr-core."))
            } else {
                lastMissed = now()
                restart()
            }
        case .error(let kind, let message):
            fail(.unavailable(message.isEmpty ? kind : message))
        case .heartbeat, .other, nil:
            break
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.fail(.unavailable("herdr-core stopped answering."))
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceLimit, execute: work)
    }

    private func fail(_ new: State) {
        retryWork?.cancel()
        retryWork = nil
        watchdog?.cancel()
        watchdog = nil
        generation &+= 1
        connection?.cancel()
        connection = nil
        if let liveSince, now().timeIntervalSince(liveSince) >= Self.stableInterval {
            retryDelay = HerdrBridge.firstRetryDelay
        }
        liveSince = nil
        clearTerminals()
        switch new {
        case .unavailable(let reason): setState(.unavailable(HerdrBridge.cleanName(reason)))
        default: setState(new)
        }
        guard !isStopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, HerdrBridge.longestRetryDelay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onChange(.structure)
    }

    private func clearTerminals() {
        guard !terminals.isEmpty else { return }
        let old = agents
        terminals.removeAll()
        report(from: old)
        onChange(.structure)
    }

    // MARK: Applying

    /// Replaces the cache. A status that differs from the cached one is
    /// reported, so a change that happened while events were missed is
    /// still seen.
    private func apply(snapshot: [HerdrCoreRaw], seq: UInt64) {
        let old = agents
        terminals = Dictionary(snapshot.map { ($0.address, Self.cleaned($0)) }, uniquingKeysWith: { _, last in last })
        self.seq = seq
        if liveSince == nil { liveSince = now() }
        armWatchdog()
        setState(.live)
        report(from: old)
        onChange(.structure)
    }

    private func apply(_ event: HerdrCoreEvent) {
        let old = agents
        switch event {
        case .upserted(_, let raw):
            guard terminals[raw.address] != nil || terminals.count < HerdrCoreProtocol.terminalLimit else { return }
            terminals[raw.address] = Self.cleaned(raw)
        case .status(_, let address, let status):
            terminals[address]?.status = status.map(Self.cleaned)
        case .labels(_, let address, let labels):
            terminals[address]?.labels = labels.mapValues(HerdrBridge.cleanName)
        case .title(_, let address, let title):
            terminals[address]?.title = HerdrBridge.cleanName(title)
        case .foreground(_, let address, let name, let cwd):
            terminals[address]?.foregroundName = name.map(HerdrBridge.cleanName)
            if let cwd { terminals[address]?.cwd = HerdrBridge.cleanName(cwd) }
        case .gone(_, let address):
            guard terminals.removeValue(forKey: address) != nil else { return }
        case .other:
            return
        }
        // A title change shows only through the summary it gives; the rest
        // of a title (a spinner) changes too often to redraw for.
        guard Self.listing(agents) != Self.listing(old) else { return }
        report(from: old)
        onChange(.structure)
    }

    private static func listing(_ agents: [String: HerdrCoreTerminal]) -> [String: HerdrCoreTerminal] {
        agents.mapValues { var agent = $0; agent.title = ""; return agent }
    }

    /// Reports each agent whose status moved, keyed by address, as the
    /// herdr 0.9 bridge does by pane.
    private func report(from old: [String: HerdrCoreTerminal]) {
        let new = agents
        for address in Set(old.keys).union(new.keys).sorted() {
            let before = old[address]?.status ?? .unknown
            let after = new[address]?.status ?? .unknown
            if before != after {
                onChange(.status(
                    paneID: address,
                    agent: new[address]?.agent ?? old[address]?.agent,
                    from: before,
                    to: after
                ))
            }
        }
    }

    /// Program-written text, cleaned once as it arrives.
    private static func cleaned(_ raw: HerdrCoreRaw) -> HerdrCoreRaw {
        var raw = raw
        raw.status = raw.status.map(cleaned)
        raw.title = HerdrBridge.cleanName(raw.title)
        raw.name = raw.name.map(HerdrBridge.cleanName)
        raw.foregroundName = raw.foregroundName.map(HerdrBridge.cleanName)
        raw.labels = raw.labels.mapValues(HerdrBridge.cleanName)
        raw.cwd = HerdrBridge.cleanName(raw.cwd)
        return raw
    }

    private static func cleaned(_ status: [String: String]) -> [String: String] {
        var status = status
        for key in ["app", "kind", "title"] {
            status[key] = status[key].map(HerdrBridge.cleanName)
        }
        status["msg"] = status["msg"].map {
            TerminalNotificationParser.clean($0, limit: TerminalNotificationParser.bodyLimit)
        }
        return status
    }
}
