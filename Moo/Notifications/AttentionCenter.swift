//
//  AttentionCenter.swift
//  Moo
//
//  Notifications a program in a terminal sends on purpose — "Claude is
//  waiting for your input" — gathered into one list. Each entry remembers the
//  pane it came from, so opening it goes straight back to that window,
//  workspace, tab and split.
//
//  This is the truthful "waiting" signal ProjectRuntime refuses to guess at.
//  Nothing here is inferred from silence or process state: an entry exists
//  only because the program asked for one.
//
//  An entry stays unread until the user looks at its pane (focuses it in the
//  key window) or opens it from a list. A notification from the pane the user
//  is already looking at is dropped: it has nothing to tell them.
//

import AppKit
import Foundation
import Observation
import UserNotifications

struct AttentionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The pane that sent it: `TerminalSessionController.id`, which the shell
    /// also sees as MOO_SURFACE_ID.
    let surfaceID: UUID
    var date: Date
    var title: String
    var body: String
    /// Where it came from, "Project › Tab". Captured on arrival rather than
    /// looked up later, so an entry still reads sensibly after its tab is
    /// retitled.
    var location: String
    var isRead: Bool
}

@Observable
final class AttentionCenter {
    static let shared = AttentionCenter()

    /// Older entries fall off the end.
    static let historyLimit = 50
    /// What a banner carries back when it is clicked.
    nonisolated static let itemIDKey = "MooAttentionItemID"

    /// Newest first.
    private(set) var items: [AttentionItem] = []

    /// Panes with at least one unread entry. Kept beside `items` because a
    /// focused terminal reports focus on nearly every pass of the event loop,
    /// and that check has to be a set lookup.
    @ObservationIgnored private var unreadSurfaces: Set<UUID> = []
    @ObservationIgnored private let integratesWithSystem: Bool
    @ObservationIgnored private var bannerDelegate: AttentionBannerDelegate?
    @ObservationIgnored private var authorization: Task<Void, Never>?

    /// `integratesWithSystem: false` keeps tests away from the Dock, the
    /// sidebar and Notification Center.
    init(integratesWithSystem: Bool = true) {
        self.integratesWithSystem = integratesWithSystem
    }

    var unreadCount: Int {
        items.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    var latestUnread: AttentionItem? {
        items.first { !$0.isRead }
    }

    /// Unread entries from any of these panes, newest first.
    func unreadItems(from surfaceIDs: Set<UUID>) -> [AttentionItem] {
        items.filter { !$0.isRead && surfaceIDs.contains($0.surfaceID) }
    }

    func hasUnread(from controllers: [TerminalSessionController]) -> Bool {
        items.contains { item in
            !item.isRead && controllers.contains { $0.id == item.surfaceID }
        }
    }

    // MARK: Arriving

    func post(_ notification: TerminalNotification, from controller: TerminalSessionController) {
        guard !Self.isLookingAt(controller) else { return }
        record(notification, surfaceID: controller.id, location: Self.location(of: controller))
    }

    /// Adds an entry. A repeat of the pane's newest unread entry refreshes its
    /// time instead of stacking a copy, and does not banner again: agents
    /// re-send "waiting" for as long as they keep waiting.
    @discardableResult
    func record(
        _ notification: TerminalNotification,
        surfaceID: UUID,
        location: String,
        now: Date = Date()
    ) -> AttentionItem {
        if let index = items.firstIndex(where: { !$0.isRead && $0.surfaceID == surfaceID }),
           items[index].title == notification.title,
           items[index].body == notification.body {
            var repeated = items.remove(at: index)
            repeated.date = now
            items.insert(repeated, at: 0)
            didChange()
            return repeated
        }

        let item = AttentionItem(
            id: UUID(),
            surfaceID: surfaceID,
            date: now,
            title: notification.title,
            body: notification.body,
            location: location,
            isRead: false
        )
        items.insert(item, at: 0)
        if items.count > Self.historyLimit {
            let dropped = items[Self.historyLimit...].map(\.id)
            items.removeLast(items.count - Self.historyLimit)
            withdrawBanners(dropped)
        }
        didChange()
        deliverBanner(for: item)
        // Installed only at app launch, like banners, so tests stay silent.
        if integratesWithSystem, bannerDelegate != nil {
            AttentionAlerts.shared.alert(for: item)
        }
        return item
    }

    // MARK: Reading

    /// The user is looking at a pane, so everything it said has been seen.
    func markRead(surfaceID: UUID) {
        guard unreadSurfaces.contains(surfaceID) else { return }
        var read: [UUID] = []
        for index in items.indices where items[index].surfaceID == surfaceID && !items[index].isRead {
            items[index].isRead = true
            read.append(items[index].id)
        }
        didChange()
        withdrawBanners(read)
    }

    func markAllRead() {
        guard !unreadSurfaces.isEmpty else { return }
        let read = items.filter { !$0.isRead }.map(\.id)
        for index in items.indices {
            items[index].isRead = true
        }
        didChange()
        withdrawBanners(read)
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        let removed = items.map(\.id)
        items.removeAll()
        didChange()
        withdrawBanners(removed)
    }

    /// A pane closed; its entries have nowhere to lead.
    func removeItems(from surfaceID: UUID) {
        let removed = items.filter { $0.surfaceID == surfaceID }.map(\.id)
        guard !removed.isEmpty else { return }
        items.removeAll { $0.surfaceID == surfaceID }
        didChange()
        withdrawBanners(removed)
    }

    /// Drops entries whose pane no longer exists. Closing a pane removes its
    /// entries directly; this catches panes that went away some other way,
    /// such as a whole window closing.
    func pruneClosedSurfaces() {
        let live = Set(Self.liveControllers().map(\.id))
        for surfaceID in Set(items.map(\.surfaceID)).subtracting(live) {
            removeItems(from: surfaceID)
        }
    }

    // MARK: Going there

    func open(_ itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        guard let controller = Self.controller(for: item.surfaceID) else {
            removeItems(from: item.surfaceID)
            return
        }
        markRead(surfaceID: item.surfaceID)
        AttentionNavigator.reveal(controller)
    }

    func openLatestUnread() {
        guard let item = latestUnread else { return }
        open(item.id)
    }

    // MARK: Surroundings

    /// The Dock badge: the unread count, or nothing.
    var dockBadgeLabel: String? {
        let count = unreadCount
        return count > 0 ? String(count) : nil
    }

    /// What the Dock should show, honoring the setting that turns it off.
    var displayedDockBadgeLabel: String? {
        AttentionDefaults.dockBadgeEnabled ? dockBadgeLabel : nil
    }

    /// Re-applies the badge after its setting changes.
    func refreshDockBadge() {
        guard integratesWithSystem else { return }
        NSApp.dockTile.badgeLabel = displayedDockBadgeLabel
    }

    /// Settings' "Send Test Notification": every enabled alert fires, but
    /// nothing is added to the list — a test entry would lead nowhere.
    func sendTestAlert() {
        let item = AttentionItem(
            id: UUID(),
            surfaceID: UUID(),
            date: Date(),
            title: "Moo",
            body: "This is how a waiting pane gets your attention",
            location: "Settings",
            isRead: false
        )
        deliverBanner(for: item)
        guard integratesWithSystem, bannerDelegate != nil else { return }
        AttentionAlerts.shared.alert(for: item, isTest: true)
    }

    private func didChange() {
        unreadSurfaces = Set(items.lazy.filter { !$0.isRead }.map(\.surfaceID))
        guard integratesWithSystem else { return }
        NSApp.dockTile.badgeLabel = displayedDockBadgeLabel
        // The sidebar's "waiting" status is computed from this list.
        ProjectRuntime.shared.invalidate()
    }

    /// True when the pane is the focused terminal of the key window of the
    /// active app — the only case where a notification would tell the user
    /// nothing they cannot already see.
    static func isLookingAt(_ controller: TerminalSessionController) -> Bool {
        guard NSApp.isActive,
              let terminal = controller.terminal,
              let window = terminal.window,
              window.isKeyWindow else {
            return false
        }
        return window.firstResponder === terminal
    }

    /// "Project › Tab". The tab part is the sending pane's own title, which in
    /// a split can differ from the one the tab strip shows.
    static func location(of controller: TerminalSessionController) -> String {
        let runtime = ProjectRuntime.shared
        var parts: [String] = []
        let paneTitle = controller.tabTitle
        if let location = runtime.location(of: controller) {
            if let project = AppModel.shared.projects.projects.first(where: { $0.id == location.projectID }) {
                parts.append(project.displayName(
                    directory: runtime.currentDirectory(for: location.projectID)
                ))
            }
            parts.append(paneTitle.isEmpty ? location.tab.displayTitle : paneTitle)
        } else {
            parts.append(paneTitle)
        }
        var seen = Set<String>()
        return parts
            .map { TerminalNotificationParser.clean($0, limit: TerminalNotificationParser.titleLimit) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " › ")
    }

    private static func liveControllers() -> [TerminalSessionController] {
        var controllers = ProjectRuntime.shared.allControllers
        for window in NSApp.windows {
            for controller in TerminalSessionRegistry.shared.controllers(for: window)
            where !controllers.contains(where: { $0 === controller }) {
                controllers.append(controller)
            }
        }
        return controllers
    }

    private static func controller(for surfaceID: UUID) -> TerminalSessionController? {
        liveControllers().first { $0.id == surfaceID }
    }

    // MARK: Banners

    /// Becomes the notification center's delegate so a clicked banner comes
    /// back here. Called once at launch; until it is, no banners are sent.
    func installBannerHandling() {
        guard integratesWithSystem, bannerDelegate == nil else { return }
        let delegate = AttentionBannerDelegate()
        bannerDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    private func deliverBanner(for item: AttentionItem) {
        guard integratesWithSystem, bannerDelegate != nil, AttentionDefaults.bannersEnabled else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = item.title.isEmpty ? "Moo" : item.title
        content.subtitle = item.location
        content.body = item.body
        // Silent: AttentionAlerts plays the sound chosen in Settings, which
        // also works with banners off or Notification Center permission denied.
        content.sound = nil
        content.threadIdentifier = item.surfaceID.uuidString
        content.userInfo = [Self.itemIDKey: item.id.uuidString]
        let request = UNNotificationRequest(
            identifier: item.id.uuidString,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        // Permission is asked the first time a banner is due, not at launch,
        // so someone who never runs an agent is never prompted.
        let authorization = self.authorization ?? Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        self.authorization = authorization
        Task {
            await authorization.value
            try? await center.add(request)
        }
    }

    /// Read entries leave Notification Center too, so it never holds a
    /// "waiting" the user has already dealt with.
    private func withdrawBanners(_ itemIDs: [UUID]) {
        guard integratesWithSystem, bannerDelegate != nil, !itemIDs.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: itemIDs.map(\.uuidString))
    }
}

/// Receives clicks on Moo's banners. Nonisolated: the notification center
/// calls these off the main thread.
nonisolated final class AttentionBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Moo is frontmost, but the user is somewhere else in it. Show the
    /// banner without a sound over whatever they are doing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[AttentionCenter.itemIDKey] as? String,
              let itemID = UUID(uuidString: raw) else {
            return
        }
        await MainActor.run {
            AttentionCenter.shared.open(itemID)
        }
    }
}

/// Brings a pane on screen: its window forward, its workspace selected in
/// that window, its tab selected, and the pane focused.
enum AttentionNavigator {
    static func reveal(_ controller: TerminalSessionController, mayOpenWindow: Bool = true) {
        NSApp.activate(ignoringOtherApps: true)
        let runtime = ProjectRuntime.shared

        guard let location = runtime.location(of: controller) else {
            // A terminal outside every workspace: its window is all there is.
            bringForward(controller.terminal?.window)
            focus(controller)
            return
        }

        guard let scope = runtime.scope(showing: location.projectID) ?? frontmostScope(in: runtime) else {
            // Every window is closed but the workspace is still running. Open
            // one, and try again once it has registered its scope.
            guard mayOpenWindow else { return }
            WindowOpener.openWindow(spec: LaunchSpec())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                reveal(controller, mayOpenWindow: false)
            }
            return
        }

        // Raises the window already showing the workspace, or switches this
        // one to it — the same rule the sidebar follows.
        runtime.select(projectID: location.projectID, in: scope)
        location.session.select(location.tab)
        location.tab.panes?.markFocused(controller)
        runtime.invalidate()
        bringForward(runtime.scope(showing: location.projectID)?.window ?? scope.window)
        focus(controller)
    }

    /// The window scope nearest the front, for a workspace no window shows.
    private static func frontmostScope(in runtime: ProjectRuntime) -> WindowScope? {
        for window in NSApp.orderedWindows {
            if let scope = runtime.scopes.first(where: { $0.window === window }) {
                return scope
            }
        }
        return runtime.scopes.last
    }

    private static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A terminal only takes focus in the active key window, and activation
    /// lands a turn or two after it is asked for — so ask again as it settles.
    private static func focus(_ controller: TerminalSessionController) {
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                controller.requestFocus()
            }
        }
    }
}
