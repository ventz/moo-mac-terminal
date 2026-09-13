//
//  ProjectRuntime.swift
//  Moo
//
//  The live half of the projects feature. Binds each project to the window
//  tab group presenting it, and derives the status shown in the sidebar.
//
//  Nothing here is persisted. A project that has never been opened in this
//  run is `.cold`; opening it lazily launches its first terminal.
//

import AppKit
import Combine
import Darwin
import Foundation
import Observation
import SwiftTerm

/// What a project's sidebar row reports. Ordered by display priority: a
/// project showing several of these at once reports the highest.
///
/// `waiting` is never inferred. A terminal cannot know that an agent is
/// blocked on the user — guessing from silence or from a sleeping process
/// produces false positives on pagers, editors, `sudo`, `ssh` and quiet
/// builds. It comes only from a program saying so with a notification escape
/// sequence, collected by AttentionCenter.
enum ProjectStatus: Int, Comparable, Sendable {
    /// No session has been started for this project in this run.
    case cold = 0
    /// A shell is up and sitting at a prompt.
    case idle = 1
    /// A command is running.
    case running = 2
    /// Output arrived while the project was not frontmost.
    case attention = 3
    /// A program in one of the project's panes sent a notification the user
    /// has not looked at yet.
    case waiting = 4

    static func < (lhs: ProjectStatus, rhs: ProjectStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .cold: return "Not running"
        case .idle: return "Idle"
        case .running: return "Running"
        case .attention: return "Activity"
        case .waiting: return "Waiting"
        }
    }
}

/// Why a status was reported. Kept alongside the status so the reason a row is
/// lit is inspectable rather than folklore.
enum ProjectStatusSource: String, Sendable {
    case noSession
    case notification
    case unreadOutput
    case childProcess
    case atPrompt
}

struct ProjectStatusReport: Equatable, Sendable {
    var status: ProjectStatus
    var source: ProjectStatusSource
    /// How many of the project's sessions have unread output — or, while
    /// waiting, how many unread notifications there are.
    var attentionCount: Int
    /// The newest unread notification's text, while waiting.
    var message: String? = nil

    static let cold = ProjectStatusReport(
        status: .cold,
        source: .noSession,
        attentionCount: 0
    )
}

@Observable
@MainActor
final class ProjectRuntime {
    static let shared = ProjectRuntime()

    /// Bumped whenever a binding or derived value changes, so views observing
    /// the runtime refresh without observing every controller individually.
    private(set) var revision = 0


    /// Cached git branch keyed by directory path. An empty string is a
    /// cached "not a repository", so misses are not rescanned endlessly.
    @ObservationIgnored private var branches: [String: String] = [:]
    @ObservationIgnored private var branchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var lastOutputPoll: TimeInterval = 0


    init(startsProcesses: Bool = true) {
        self.startsProcesses = startsProcesses
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            Notification.Name.terminalFocusedPaneDidChange,
            Notification.Name.terminalWorkingDirectoryDidChange
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.windowWillClose(note.object as? NSWindow)
            }
        })
        startPollingStatus()
    }

    /// Signals a structural change: a workspace selected, a tab added or
    /// closed, a directory reported. Statuses are recomputed at the same time
    /// so a row is never left describing the shape the workspace used to have
    /// — the timer only has to catch process transitions.
    func invalidate() {
        pollStatus()
        revision &+= 1
    }

    deinit {
        statusTimer?.invalidate()
    }

    // MARK: Keeping status honest

    /// Nothing notifies the app when a shell's child process exits, so a row
    /// would otherwise read "Running" until some unrelated event forced a
    /// recompute — which is why status only refreshed after clicking away.
    ///
    /// The poll writes into `session.status`; SwiftUI observes that property,
    /// so only rows whose status actually moved are redrawn. It deliberately
    /// does not touch `revision`: bumping a global counter on every tick
    /// redrew the whole sidebar several times a second.
    private func startPollingStatus() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStatus() }
        }
    }

    private func pollStatus() {
        for (id, session) in sessions {
            let current = computeStatus(for: id)
            if session.status != current {
                session.status = current
            }
        }
        pruneChildBookkeeping()
    }

    /// Forgets child timings for controllers that no longer exist, so a
    /// long-lived app does not accumulate an entry per closed pane.
    private func pruneChildBookkeeping() {
        guard !childFirstSeen.isEmpty else { return }
        let live = Set(sessions.values.flatMap(\.controllers).map(ObjectIdentifier.init))
        childFirstSeen = childFirstSeen.filter { live.contains($0.key) }
    }

    /// A finishing command always writes at least a new prompt, so output is a
    /// good moment to re-check. Throttled, because output arrives far faster
    /// than a status can meaningfully change.
    func noteTerminalOutput() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastOutputPoll > 0.2 else { return }
        lastOutputPoll = now
        pollStatus()
    }

    // MARK: Sessions

    /// The live contents of each workspace, owned here rather than by any
    /// view. This is what lets a workspace keep running while it is off
    /// screen: SwiftUI can discard the views, but never these.
    @ObservationIgnored private var sessions: [UUID: WorkspaceSession] = [:]

    // MARK: Per-window selection

    /// Every window's scope, newest last. A window registers on appear and
    /// unregisters on close.
    @ObservationIgnored private(set) var scopes: [WindowScope] = []

    /// Used when no window has registered — tests, and previews.
    @ObservationIgnored private lazy var detachedScope = WindowScope()

    func register(_ scope: WindowScope) {
        guard !scopes.contains(where: { $0 === scope }) else { return }
        scopes.append(scope)
        invalidate()
    }

    func unregister(_ scope: WindowScope) {
        scopes.removeAll { $0 === scope }
        invalidate()
    }

    /// The scope menu commands act on: the key window's, falling back to the
    /// main window's, then to the only window, then to the detached scope.
    var keyScope: WindowScope {
        // The key window is not observable, but becoming key invalidates the
        // runtime. Reading the revision here is what lets menu titles and
        // commands follow the window in front instead of going stale.
        _ = revision
        if let key = NSApp.keyWindow,
           let scope = scopes.first(where: { $0.window === key }) {
            return scope
        }
        if let main = NSApp.mainWindow,
           let scope = scopes.first(where: { $0.window === main }) {
            return scope
        }
        if scopes.count == 1, let only = scopes.first { return only }
        return scopes.last ?? detachedScope
    }

    /// The scope showing a workspace, if any window is.
    func scope(showing projectID: UUID) -> WindowScope? {
        scopes.first { $0.selectedProjectID == projectID }
    }

    /// The scope whose on-screen tab holds a controller: the window a terminal
    /// is actually in, which is not necessarily the key window.
    func scope(showing controller: TerminalSessionController) -> WindowScope? {
        // Sessions are looked up here rather than through WindowScope.session,
        // which always asks the shared runtime.
        scopes.first { scope in
            scope.selectedProjectID
                .flatMap { sessions[$0] }?
                .selectedTab?.controllers.contains { $0 === controller } ?? false
        }
    }

    // MARK: Closing a window

    /// The workspaces closing a window ends: the one it shows, or — when it is
    /// the last window, leaving nothing to reach them from — every workspace.
    private func projectIDsEnded(byClosing scope: WindowScope) -> [UUID] {
        if scopes.allSatisfy({ $0 === scope }) {
            return Array(sessions.keys)
        }
        return [scope.selectedProjectID].compactMap { $0 }
    }

    /// What closing a window would end, for the confirmation. Empty for a
    /// window that shows no workspace, such as Settings.
    func sessionsEnded(byClosing window: NSWindow) -> [WorkspaceSession] {
        guard let scope = scopes.first(where: { $0.window === window }) else { return [] }
        return projectIDsEnded(byClosing: scope)
            .compactMap { sessions[$0] }
            .filter { !$0.isEmpty }
    }

    /// A window is closing: end what it held. A session is never kept alive
    /// without a window or tab to reach it from.
    ///
    /// The scope is marked closed and deselected *before* its sessions are
    /// discarded. Its view can render once more, and a window still selecting
    /// a workspace that is gone would build a fallback terminal and start a
    /// shell in a window nobody can see.
    func windowWillClose(_ window: NSWindow?) {
        guard let window,
              let scope = scopes.first(where: { $0.window === window }) else { return }
        let ended = projectIDsEnded(byClosing: scope)
        scope.isClosed = true
        scope.selectedProjectID = nil
        unregister(scope)
        for projectID in ended {
            discardSession(for: projectID)
        }
    }

    /// cmd+B. Toggles the sidebar in one window only.
    func toggleSidebar(in scope: WindowScope) {
        setSidebarVisible(!scope.isSidebarVisible, in: scope)
    }

    /// Shows or hides one window's sidebar, and remembers the choice as what
    /// the next new window starts with.
    func setSidebarVisible(_ visible: Bool, in scope: WindowScope) {
        scope.isSidebarVisible = visible
        UserDefaults.standard.set(visible, forKey: ProjectSidebarDefaults.isVisible)
        invalidate()
    }

    /// True when any window is showing this workspace.
    func isVisible(_ projectID: UUID) -> Bool {
        scope(showing: projectID) != nil || detachedScope.selectedProjectID == projectID
    }

    /// Which workspace the key window is showing. Menu commands read this.
    var selectedProjectID: UUID? {
        keyScope.selectedProjectID
    }

    @ObservationIgnored private let startsProcesses: Bool

    /// The session for a workspace, created on first use. Creating a session
    /// does not start a shell; the first tab does that.
    func session(for projectID: UUID) -> WorkspaceSession {
        if let existing = sessions[projectID] { return existing }
        let session = WorkspaceSession(projectID: projectID, startsProcesses: startsProcesses)
        sessions[projectID] = session
        return session
    }

    func existingSession(for projectID: UUID) -> WorkspaceSession? {
        sessions[projectID]
    }

    var selectedSession: WorkspaceSession? {
        keyScope.session
    }

    /// Switches the window to a workspace.
    ///
    /// Nothing is created, hidden or destroyed at the window level — only the
    /// terminal area's contents change — so the switch is seamless and cannot
    /// disturb any other workspace's shells.
    func select(projectID: UUID) {
        select(projectID: projectID, in: keyScope)
    }

    /// Switches one window to a workspace.
    ///
    /// If another window already shows it, that window is brought forward and
    /// nothing moves. A workspace's terminals are live AppKit views that can
    /// only be in one window, so showing one in two places would tear it out
    /// of the first — the bug this rule exists to prevent.
    func select(projectID: UUID, in scope: WindowScope) {
        if let other = self.scope(showing: projectID), other !== scope {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }
        let session = session(for: projectID)
        session.ensureTab()
        guard scope.selectedProjectID != projectID else {
            invalidate()
            return
        }
        scope.selectedProjectID = projectID
        UserDefaults.standard.set(
            projectID.uuidString,
            forKey: ProjectSidebarDefaults.selectedProjectID
        )
        invalidate()
    }

    /// The workspace a newly opened window should adopt: the first one no
    /// other window is showing. Nil when every workspace is already on screen,
    /// which is the caller's cue to create one.
    func firstUnshownProject(among projects: [Project]) -> Project? {
        projects.first { scope(showing: $0.id) == nil }
    }

    /// Closes the workspace tab that owns a session controller.
    ///
    /// Returns false when the controller belongs to no workspace tab, in which
    /// case the caller falls back to closing the window as it always did.
    @discardableResult
    func closeTab(containing controller: TerminalSessionController) -> Bool {
        for session in sessions.values {
            guard let tab = session.tabs.first(where: { tab in
                tab.controllers.contains(where: { $0 === controller })
            }) else {
                continue
            }
            session.close(tab)
            invalidate()
            return true
        }
        return false
    }

    struct ControllerLocation {
        let projectID: UUID
        let session: WorkspaceSession
        let tab: WorkspaceTab
    }

    /// The workspace and tab a controller lives in, on screen or not. Nil for
    /// a terminal outside every workspace.
    func location(of controller: TerminalSessionController) -> ControllerLocation? {
        for (projectID, session) in sessions {
            if let tab = session.tab(containing: controller) {
                return ControllerLocation(projectID: projectID, session: session, tab: tab)
            }
        }
        return nil
    }


    /// Closes the visible workspace's active tab. Returns false when there is
    /// nothing to close, or when the workspace holds only one tab — a lone tab
    /// is the window, so closing it is the window's business.
    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let session = selectedSession,
              session.tabs.count > 1,
              let tab = session.selectedTab else {
            return false
        }
        session.close(tab)
        invalidate()
        return true
    }

    /// Drops a workspace's session entirely, ending its shells. Only called
    /// when the workspace itself is deleted.
    func discardSession(for projectID: UUID) {
        sessions.removeValue(forKey: projectID)?.terminateAll()
        for scope in scopes where scope.selectedProjectID == projectID {
            scope.selectedProjectID = nil
        }
        if detachedScope.selectedProjectID == projectID {
            detachedScope.selectedProjectID = nil
        }
        invalidate()
    }

    /// True once a workspace has been visited and has tabs.
    func isRunning(_ projectID: UUID) -> Bool {
        !(sessions[projectID]?.isEmpty ?? true)
    }

    /// Every controller across every workspace, on screen or not. Used for
    /// quit confirmation, which must account for hidden workspaces too.
    var allControllers: [TerminalSessionController] {
        sessions.values.flatMap(\.controllers)
    }

    // MARK: Status

    /// The stored status. Reading it inside a view's body means that view
    /// re-renders when *this* workspace's status changes, and not when
    /// anything else in the app ticks.
    func status(for projectID: UUID) -> ProjectStatusReport {
        sessions[projectID]?.status ?? .cold
    }

    /// Works out what a workspace's status should be right now. Called by the
    /// poll below, never during a view update.
    private func computeStatus(for projectID: UUID) -> ProjectStatusReport {
        guard let session = sessions[projectID], !session.isEmpty else { return .cold }
        let controllers = session.controllers
        guard !controllers.isEmpty else { return .cold }

        // Before the visibility check: a notification stays unread until its
        // own pane is looked at, even in a workspace that is on screen.
        let waiting = AttentionDefaults.marksWaitingEnabled
            ? AttentionCenter.shared.unreadItems(from: Set(controllers.map(\.id)))
            : []
        if let newest = waiting.first {
            return ProjectStatusReport(
                status: .waiting,
                source: .notification,
                attentionCount: waiting.count,
                message: newest.body.isEmpty ? newest.title : newest.body
            )
        }

        // A workspace on screen in any window has no "unread" output.
        let isVisible = isVisible(projectID)
        let attentionCount = isVisible ? 0 : controllers.filter(\.hasActivity).count
        if attentionCount > 0 {
            return ProjectStatusReport(
                status: .attention,
                source: .unreadOutput,
                attentionCount: attentionCount
            )
        }
        let now = Date.timeIntervalSinceReferenceDate
        // Evaluated for every controller, not short-circuited: each one has to
        // tick its own child bookkeeping or a background pane's children would
        // freeze at whatever they were when a nearer pane first matched.
        let running = controllers.reduce(into: false) { result, controller in
            if hasSettledChild(controller, now: now) { result = true }
        }
        if running {
            return ProjectStatusReport(status: .running, source: .childProcess, attentionCount: 0)
        }
        return ProjectStatusReport(status: .idle, source: .atPrompt, attentionCount: 0)
    }

    /// How long a child has to still be the *same* process before it counts as
    /// a running command.
    private static let settleInterval: TimeInterval = 0.4

    /// When each of a controller's current children was first seen, keyed by
    /// controller. Entries are dropped as soon as the child exits, so a reused
    /// pid starts its clock over.
    @ObservationIgnored private var childFirstSeen: [ObjectIdentifier: [pid_t: TimeInterval]] = [:]

    /// A command is running when the shell has at least one child that has
    /// been there a moment — the same signal the close-confirmation policy
    /// trusts, with the flashes filtered out.
    ///
    /// Merely typing forks processes: the prompt's `git`, completion, and
    /// anything else the shell shells out to live for a few milliseconds. The
    /// status is polled on every keystroke's echo, so those were enough to
    /// make a row read "Running" while the user was only typing. Requiring the
    /// same pid across polls fixes it structurally — a fresh fork per keypress
    /// never survives, a real command always does.
    private func hasSettledChild(_ controller: TerminalSessionController, now: TimeInterval) -> Bool {
        let key = ObjectIdentifier(controller)
        guard let process = controller.terminal?.process, process.running else {
            childFirstSeen.removeValue(forKey: key)
            return false
        }
        let current = Self.childPIDs(parentPID: process.shellPid)
        guard !current.isEmpty else {
            childFirstSeen.removeValue(forKey: key)
            return false
        }
        var seen = (childFirstSeen[key] ?? [:]).filter { current.contains($0.key) }
        var settled = false
        for pid in current {
            let firstSeen = seen[pid] ?? now
            seen[pid] = firstSeen
            if now - firstSeen >= Self.settleInterval { settled = true }
        }
        childFirstSeen[key] = seen
        return settled
    }

    nonisolated private static func childPIDs(parentPID: pid_t) -> Set<pid_t> {
        guard parentPID > 0 else { return [] }
        var childPIDs = [pid_t](repeating: 0, count: 256)
        let count = childPIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(
                parentPID,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard count > 0 else { return [] }
        return Set(childPIDs.prefix(min(Int(count), childPIDs.count)).filter { $0 > 0 })
    }

    // MARK: Live location

    /// Every tab's directory, in tab order, for the sidebar subtitle. Tabs
    /// that have not reported one yet are skipped rather than shown blank.
    func tabDirectories(for projectID: UUID) -> [String] {
        guard let session = sessions[projectID] else { return [] }
        return session.tabs.compactMap(\.currentDirectory)
    }

    /// The directory the workspace is *currently* in, read from the terminal
    /// itself (OSC 7). A workspace is a label, not a folder — so this follows
    /// the user around as they `cd`, and there is nothing stored to go stale.
    func currentDirectory(for projectID: UUID) -> String? {
        guard let session = sessions[projectID] else { return nil }
        if let directory = session.selectedTab?.currentDirectory {
            return directory
        }
        return session.tabs.compactMap(\.currentDirectory).first
    }

    // MARK: Git branch

    /// Branches are cached by directory, not by project, because a project's
    /// directory changes as the user moves around.
    func branch(for projectID: UUID) -> String? {
        guard let directory = currentDirectory(for: projectID) else { return nil }
        if let cached = branches[directory] { return cached }
        refreshBranch(atPath: directory)
        return nil
    }

    /// Resolves the branch off the main actor and caches it against the path.
    func refreshBranch(atPath path: String) {
        guard branches[path] == nil, branchTasks[path] == nil else { return }
        let url = URL(fileURLWithPath: path)
        branchTasks[path] = Task { [weak self] in
            let branch = await Self.resolveBranch(at: url)
            await MainActor.run {
                guard let self else { return }
                self.branchTasks[path] = nil
                // Cache the miss too, so a non-repo is not re-scanned forever.
                self.branches[path] = branch ?? ""
                self.invalidate()
            }
        }
    }

    /// Called on activation and from the sidebar, never per render.
    func refreshLocations(for projects: [Project]) {
        for project in projects {
            if let directory = currentDirectory(for: project.id) {
                refreshBranch(atPath: directory)
            }
        }
    }

    /// Reads .git directly rather than shelling out to git, so the sidebar
    /// never spawns a process per project per refresh. Handles worktrees
    /// (.git as a file) and detached HEAD (shows a short SHA).
    nonisolated private static func resolveBranch(at url: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let fileManager = FileManager.default
            var gitPath = url.appendingPathComponent(".git")

            // Walk up until a .git is found, so a subdirectory of a repo still
            // reports the repo's branch.
            var searchURL = url
            while !fileManager.fileExists(atPath: gitPath.path) {
                let parent = searchURL.deletingLastPathComponent()
                guard parent.path != searchURL.path, parent.path != "/" else { return nil }
                searchURL = parent
                gitPath = searchURL.appendingPathComponent(".git")
            }

            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: gitPath.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                // A worktree or submodule: ".git" is a file holding "gitdir: <path>".
                guard let contents = try? String(contentsOf: gitPath, encoding: .utf8),
                      let line = contents.split(separator: "\n").first(where: {
                          $0.hasPrefix("gitdir:")
                      }) else {
                    return nil
                }
                let raw = line.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                gitPath = raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw)
                    : searchURL.appendingPathComponent(raw).standardizedFileURL
            }

            guard let head = try? String(
                contentsOf: gitPath.appendingPathComponent("HEAD"),
                encoding: .utf8
            ) else {
                return nil
            }
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "ref: refs/heads/") {
                return String(trimmed[range.upperBound...])
            }
            // Detached HEAD: the file holds a raw SHA.
            guard trimmed.count >= 7 else { return nil }
            return String(trimmed.prefix(7))
        }.value
    }
}

