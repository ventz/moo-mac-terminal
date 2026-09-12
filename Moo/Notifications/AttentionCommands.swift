//
//  AttentionCommands.swift
//  Moo
//
//  The notification list in the Window menu, with shift+cmd+U to go to the
//  newest unread entry from anywhere in the app.
//

import SwiftUI

extension Color {
    /// The mark for a pane that asked for the user: the sidebar's "waiting"
    /// dot and the tab strip's, kept identical so they read as one signal.
    static let attentionWaiting = Color.purple
}

struct AttentionCommands: Commands {
    @State private var center = AttentionCenter.shared
    @AppStorage(AttentionDefaults.showsBanners) private var showsBanners = true
    @AppStorage(AttentionDefaults.showsStatusItem) private var showsStatusItem = true

    private static let menuLimit = 15
    private static let titleLimit = 90

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Notifications") {
                if center.items.isEmpty {
                    Button("No Notifications") {}
                        .disabled(true)
                }
                ForEach(Array(center.items.prefix(Self.menuLimit))) { item in
                    Button(Self.title(for: item)) {
                        center.open(item.id)
                    }
                }
                Divider()
                Button("Jump to Latest Unread") {
                    center.openLatestUnread()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(center.latestUnread == nil)
                Button("Mark All Read") {
                    center.markAllRead()
                }
                .disabled(center.latestUnread == nil)
                Button("Clear All") {
                    center.clearAll()
                }
                .disabled(center.items.isEmpty)
                Divider()
                Toggle("Show Banners", isOn: $showsBanners)
                Toggle("Show in Menu Bar", isOn: $showsStatusItem)
            }
        }
    }

    /// One line per entry, since a SwiftUI menu item cannot wrap: the unread
    /// mark, then what was said and where.
    static func title(for item: AttentionItem) -> String {
        let said = [item.title, item.body].filter { !$0.isEmpty }.joined(separator: ": ")
        var line = item.location.isEmpty ? said : "\(said) — \(item.location)"
        if line.count > titleLimit {
            line = String(line.prefix(titleLimit - 1)) + "…"
        }
        return (item.isRead ? "     " : "●  ") + line
    }
}
