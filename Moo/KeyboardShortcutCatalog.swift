//
//  KeyboardShortcutCatalog.swift
//  Moo
//
//  Every shortcut Moo defines, grouped by the part of the app it drives.
//  Settings → Keyboard lists it and docs/SHORTCUTS.md documents it.
//  KeyboardShortcutCatalogTests fails when a menu shortcut in the source is
//  missing here, or an entry here is missing from the doc.
//

import Foundation

enum KeyboardShortcutCatalog {
    struct Shortcut: Identifiable {
        /// One or more key combinations, shown joined by " / ".
        let keys: [String]
        let action: String

        var id: String { displayKeys + action }
        var displayKeys: String { keys.joined(separator: " / ") }

        init(_ keys: String..., action: String) {
            self.keys = keys
            self.action = action
        }
    }

    struct Group: Identifiable {
        let title: String
        let shortcuts: [Shortcut]

        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Windows & Projects", shortcuts: [
            Shortcut("⌘N", action: "New window, or a new project while the sidebar is open"),
            Shortcut("⌥⌘N", action: "New window"),
            Shortcut("⇧⌘P", action: "New project"),
            Shortcut("⌘B", action: "Show or hide the projects sidebar"),
            Shortcut("⌘1–⌘8", "⌘9", action: "Select a project or tab (Settings → General), ⌘9 the last"),
            Shortcut("⇧⌘U", action: "Jump to the latest unread notification"),
            Shortcut("⌘,", action: "Settings")
        ]),
        Group(title: "Tabs", shortcuts: [
            Shortcut("⌘T", action: "New tab"),
            Shortcut("⇧⌘[", "⇧⌘]", action: "Previous / next tab"),
            Shortcut("⌘W", action: "Close the pane or tab")
        ]),
        Group(title: "Splits", shortcuts: [
            Shortcut("⌘D", action: "Split side by side"),
            Shortcut("⇧⌘D", action: "Split stacked"),
            Shortcut("⌘[", "⌘]", action: "Previous / next split"),
            Shortcut("⌥⌘↑", "⌥⌘↓", "⌥⌘←", "⌥⌘→", action: "Select the split in that direction"),
            Shortcut("⌃⌘↑", "⌃⌘↓", "⌃⌘←", "⌃⌘→", action: "Move the divider"),
            Shortcut("⌃⌘=", action: "Equalize splits"),
            Shortcut("⇧⌘↩", action: "Zoom or unzoom the pane")
        ]),
        Group(title: "Terminal", shortcuts: [
            Shortcut("⌘K", action: "Command palette"),
            Shortcut("⇧⌘K", action: "Clear to start (screen and scrollback)"),
            Shortcut("⌥⌘K", action: "Clear scrollback"),
            Shortcut("⌘↑", "⌘↓", action: "Scroll to the previous / next prompt"),
            Shortcut("⌘F", action: "Find"),
            Shortcut("⌘G", "⇧⌘G", action: "Find next / previous"),
            Shortcut("⌘+", "⌘-", "⌘0", action: "Bigger / smaller / default font size"),
            Shortcut("⌃⌘V", action: "Paste escaped"),
            Shortcut("⌃⌘T", action: "Change theme"),
            Shortcut("⌘P", action: "Print")
        ]),
        Group(title: "Command Palette", shortcuts: [
            Shortcut("↑", "↓", action: "Move the selection"),
            Shortcut("↩", action: "Run the command, or scroll to the match"),
            Shortcut("⌘↩", action: "Open the matched link or path"),
            Shortcut("⎋", action: "Close")
        ]),
        Group(title: "Markdown Previews", shortcuts: [
            Shortcut("⇧⌘M", action: "Open a Markdown file in a preview"),
            Shortcut("⌘[", "⌘]", action: "Back / forward through followed links"),
            Shortcut("⌘R", action: "Reload"),
            Shortcut("⌘-click", action: "Follow a link the other way: same tab or new tab (Settings → Links & Markdown)")
        ]),
        Group(title: "Browser Tabs", shortcuts: [
            Shortcut("⇧⌘B", action: "New browser tab"),
            Shortcut("⌘L", action: "Open location"),
            Shortcut("⌘[", "⌘]", action: "Back / forward"),
            Shortcut("⌘R", action: "Reload"),
            Shortcut("⌘F", action: "Find in page"),
            Shortcut("⌘G", "⇧⌘G", action: "Find next / previous"),
            Shortcut("⌘+", "⌘-", "⌘0", action: "Zoom in / out / actual size")
        ]),
        Group(title: "Mouse", shortcuts: [
            Shortcut("⌘-click", action: "Open a link, path or Markdown file from terminal output"),
            Shortcut("⌥⌘-click", action: "Open it with the default app instead"),
            Shortcut("Right-click", "⌃-click", action: "Pane menu (⌃-click goes to programs that track the mouse)")
        ])
    ]
}
