//
//  AttentionStatusItem.swift
//  Moo
//
//  The notification list in the menu bar, reachable while Moo is behind other
//  apps — which is exactly when a waiting agent goes unnoticed. The icon
//  carries the unread count; each entry opens the pane that sent it.
//
//  AppKit rather than SwiftUI's MenuBarExtra: an entry is three lines (who
//  and when, what, where), which only an attributed NSMenuItem title lays out.
//

import AppKit
import Observation

final class AttentionStatusItem: NSObject, NSMenuDelegate {
    static let shared = AttentionStatusItem()

    /// Names the app in the menu bar. A bare bell sits among other apps'
    /// icons, so the menu and tooltip say whose it is.
    static let appName = "Moo Terminal"

    /// Entries beyond this stay in the history but not in the menu.
    private static let menuLimit = 20
    /// Without a cap, one long message widens the whole menu across the screen.
    private static let lineLimit = 72

    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    func install() {
        guard defaultsObserver == nil else { return }
        // The toggle lives in two menus, one of them SwiftUI's AppStorage, so
        // follow the default itself rather than each place that writes it.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AttentionStatusItem.shared.updateVisibility()
            }
        }
        updateVisibility()
        trackUnreadCount()
    }

    private func updateVisibility() {
        let isWanted = AttentionDefaults.statusItemEnabled
        if isWanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
            updateButton()
        } else if !isWanted, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Observation tracking fires once per registration, so it re-arms itself
    /// on every change.
    private func trackUnreadCount() {
        withObservationTracking {
            _ = AttentionCenter.shared.items
        } onChange: {
            Task { @MainActor in
                AttentionStatusItem.shared.trackUnreadCount()
            }
        }
        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let unread = AttentionCenter.shared.unreadCount
        let image = NSImage(
            systemSymbolName: unread > 0 ? "bell.badge.fill" : "bell",
            accessibilityDescription: Self.toolTip(unread: unread)
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = unread > 0 ? " \(unread)" : ""
        button.toolTip = Self.toolTip(unread: unread)
    }

    static func toolTip(unread: Int) -> String {
        unread > 0 ? "\(appName): \(unreadSummary(unread))" : "\(appName) Notifications"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let center = AttentionCenter.shared
        center.pruneClosedSurfaces()
        menu.removeAllItems()

        let unread = center.unreadCount
        menu.addItem(.sectionHeader(title: Self.appName))
        let header = NSMenuItem(title: Self.unreadSummary(unread), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let entries = center.items.prefix(Self.menuLimit)
        if !entries.isEmpty {
            menu.addItem(.separator())
            for entry in entries {
                menu.addItem(menuItem(for: entry))
            }
        }

        menu.addItem(.separator())
        let jump = command("Jump to Latest Unread", #selector(openLatestUnread), enabled: unread > 0)
        jump.keyEquivalent = "u"
        jump.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(jump)
        menu.addItem(command("Mark All Read", #selector(markAllRead), enabled: unread > 0))
        menu.addItem(command("Clear All", #selector(clearAll), enabled: !center.items.isEmpty))

        menu.addItem(.separator())
        let banners = command("Show Banners", #selector(toggleBanners), enabled: true)
        banners.state = AttentionDefaults.bannersEnabled ? .on : .off
        menu.addItem(banners)
        menu.addItem(command("Hide Menu Bar Icon", #selector(hideStatusItem), enabled: true))
    }

    static func unreadSummary(_ count: Int) -> String {
        switch count {
        case 0: return "No Unread Notifications"
        case 1: return "1 Unread Notification"
        default: return "\(count) Unread Notifications"
        }
    }

    private func command(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func menuItem(for entry: AttentionItem) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.title.isEmpty ? entry.body : entry.title,
            action: #selector(openEntry(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry.id
        item.attributedTitle = Self.attributedTitle(for: entry)
        item.toolTip = [entry.title, entry.body, entry.location]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return item
    }

    /// "● Claude Code  12:08 PM" / "Claude is waiting for your input" /
    /// "Project › Tab". Read entries keep the dot's width, drawn clear, so
    /// every line lines up whether or not it is marked.
    private static func attributedTitle(for entry: AttentionItem) -> NSAttributedString {
        let regular = NSFont.menuFont(ofSize: 0)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let small = NSFont.menuFont(ofSize: regular.pointSize - 2)
        let secondary = NSColor.secondaryLabelColor
        let dotColor = entry.isRead ? NSColor.clear : NSColor.controlAccentColor
        let indent = NSAttributedString(
            string: "● ",
            attributes: [.font: regular, .foregroundColor: NSColor.clear]
        )

        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [.font: regular, .foregroundColor: dotColor]
        )
        text.append(NSAttributedString(
            string: truncated(entry.title.isEmpty ? "Terminal" : entry.title),
            attributes: [.font: entry.isRead ? regular : bold]
        ))
        text.append(NSAttributedString(
            string: "  " + timestamp(entry.date),
            attributes: [.font: small, .foregroundColor: secondary]
        ))
        if !entry.body.isEmpty {
            text.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
            text.append(indent)
            text.append(NSAttributedString(string: truncated(entry.body), attributes: [.font: regular]))
        }
        if !entry.location.isEmpty {
            text.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
            text.append(indent)
            text.append(NSAttributedString(
                string: truncated(entry.location),
                attributes: [.font: small, .foregroundColor: secondary]
            ))
        }
        return text
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > lineLimit else { return text }
        return String(text.prefix(lineLimit - 1)) + "…"
    }

    private static func timestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: Actions

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID else { return }
        AttentionCenter.shared.open(itemID)
    }

    @objc private func openLatestUnread() {
        AttentionCenter.shared.openLatestUnread()
    }

    @objc private func markAllRead() {
        AttentionCenter.shared.markAllRead()
    }

    @objc private func clearAll() {
        AttentionCenter.shared.clearAll()
    }

    @objc private func toggleBanners() {
        UserDefaults.standard.set(!AttentionDefaults.bannersEnabled, forKey: AttentionDefaults.showsBanners)
    }

    @objc private func hideStatusItem() {
        UserDefaults.standard.set(false, forKey: AttentionDefaults.showsStatusItem)
    }
}
