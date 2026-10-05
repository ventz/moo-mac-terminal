//
//  SettingsSearch.swift
//  Moo
//
//  The Settings sidebar's search. Every setting is listed here by the label
//  it shows, plus the words someone might type instead ("transparency" for
//  background opacity). A match opens the setting's page.
//
//  SettingsSearchTests scans Moo/Settings for the literal labels of
//  Toggle, Picker, Stepper, TextField, Slider and ColorPicker and fails when
//  one is missing here, so a new setting cannot go unsearchable.
//

import Foundation

enum SettingsSearch {
    struct Entry: Identifiable, Hashable {
        let title: String
        let destination: SettingsDestination
        /// The section of the page it sits in, shown under the result so two
        /// similar titles can be told apart.
        let section: String
        let keywords: String

        /// Also the anchor the page puts on the setting (`settingsAnchor`).
        var id: String { Self.anchorID(destination, title) }

        init(_ title: String, _ destination: SettingsDestination, section: String, keywords: String = "") {
            self.title = title
            self.destination = destination
            self.section = section
            self.keywords = keywords
        }

        /// Every word of the query must appear in the title, keywords or page
        /// name, so "tab opaque" finds "Keep the tab strip opaque".
        func matches(_ words: [String]) -> Bool {
            let haystack = "\(title) \(keywords) \(section) \(destination.title)"
            return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
    }

    struct Group: Equatable {
        let destination: SettingsDestination
        let entries: [Entry]
    }

    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Matches grouped by page, pages in sidebar order.
    static func results(for query: String) -> [Group] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = entries.filter { $0.matches(words) }
        return SettingsDestination.allCases.compactMap { destination in
            let found = matches.filter { $0.destination == destination }
            return found.isEmpty ? nil : Group(destination: destination, entries: found)
        }
    }

    static let entries: [Entry] = [
        // General
        Entry("Open:", .general, section: "Startup", keywords: "startup launch window group profile"),
        Entry("Profile:", .general, section: "Startup", keywords: "startup launch open"),
        Entry("Window group:", .general, section: "Startup", keywords: "startup launch open"),
        Entry("Reopen workspaces, tabs, and splits on launch", .general, section: "Startup", keywords: "restore session startup layout"),
        Entry("Restore rows of text when a saved session opens", .general, section: "Startup", keywords: "resume scrollback history"),
        Entry("Default profile:", .general, section: "New tabs and windows", keywords: "new window"),
        Entry("Open new tabs in the current tab's directory", .general, section: "New tabs and windows", keywords: "working directory cwd folder"),
        Entry("Open new tabs with the current window's profile", .general, section: "New tabs and windows"),
        Entry("⌘1–9 selects:", .general, section: "Keyboard", keywords: "command digits numbers shortcut projects tabs switch"),
        Entry("Repeat keys when held", .general, section: "Keyboard", keywords: "key repeat accent press and hold vim hjkl"),
        Entry("Keep the tab strip opaque in every profile", .general, section: "Window", keywords: "transparency translucent"),
        Entry("Draw with Metal", .general, section: "Window", keywords: "rendering gpu performance"),

        // Links & Markdown
        Entry("⌘-click opens links and Markdown files in Moo tabs", .links, section: "From the terminal", keywords: "url web command click cmd browser md open"),
        Entry("Follow the terminal theme", .links, section: "Markdown previews", keywords: "markdown preview dark light"),
        Entry("Open links to other Markdown files in new tabs", .links, section: "Markdown previews", keywords: "markdown preview back forward history navigate"),
        Entry("Block ads and trackers", .links, section: "Browser tabs", keywords: "adblock ublock content blocker browser privacy"),

        // Projects
        Entry("Status", .projects, section: "Row Contents", keywords: "sidebar row"),
        Entry("Git branch", .projects, section: "Row Contents", keywords: "sidebar row"),
        Entry("Directory path", .projects, section: "Row Contents", keywords: "sidebar row folder"),
        Entry("Accent color", .projects, section: "Row Contents", keywords: "sidebar row colour"),
        Entry("Draw a divider between the sidebar and the terminal", .projects, section: "Sidebar", keywords: "line border seamless"),
        Entry("Projects", .projects, section: "Projects", keywords: "rename remove workspace"),
        Entry("Accent", .projects, section: "Projects", keywords: "project color colour"),

        // Notifications
        Entry("Show system banners", .notifications, section: "Visual", keywords: "alerts notification center"),
        Entry("Show in menu bar", .notifications, section: "Visual", keywords: "bell status item"),
        Entry("Show unread count on the Dock icon", .notifications, section: "Visual", keywords: "badge"),
        Entry("Bounce the Dock icon", .notifications, section: "Visual", keywords: "attention"),
        Entry("Mark waiting tabs and projects", .notifications, section: "Visual", keywords: "dot attention"),
        Entry("Notify when a long command finishes out of sight", .notifications, section: "Commands", keywords: "duration seconds done"),
        Entry("Long means at least … seconds", .notifications, section: "Commands", keywords: "long command threshold duration minimum"),
        Entry("Mark tabs whose last command failed", .notifications, section: "Commands", keywords: "error exit status"),
        Entry("Sound", .notifications, section: "Audio", keywords: "audio alert"),
        Entry("Volume", .notifications, section: "Audio", keywords: "audio loud"),
        Entry("Speak the message aloud", .notifications, section: "Audio", keywords: "voice speech"),
        Entry("Play", .notifications, section: "Audio", keywords: "sound when audio"),
        Entry("Show herdr agents", .notifications, section: "herdr", keywords: "herdr agents claude codex sidebar multiplexer socket"),
        Entry("Alert when a herdr agent needs you", .notifications, section: "herdr", keywords: "herdr blocked waiting approval"),
        Entry("Alert when a herdr agent finishes", .notifications, section: "herdr", keywords: "herdr done finished turn"),

        // Profiles
        Entry("Profiles", .profiles, section: "Profiles", keywords: "create duplicate rename delete default import export mooprofile"),

        // Appearance
        Entry("Font:", .text, section: "Text", keywords: "typeface size text"),
        Entry("Cursor:", .text, section: "Text", keywords: "caret block bar underline blink"),
        Entry("Use bright colors for bold text", .text, section: "Text", keywords: "colour"),
        Entry("Background opacity:", .text, section: "Text", keywords: "transparency translucent see-through"),
        Entry("Color the window to match the theme", .text, section: "Window colors", keywords: "chrome colour title bar tabs sidebar"),
        Entry("Use the system title bar color instead (light or dark)", .text, section: "Window colors", keywords: "titlebar terminal.app native standard light"),
        Entry("Keep the projects sidebar opaque", .text, section: "Window colors", keywords: "transparency"),
        Entry("Keep the tab strip opaque", .text, section: "Window colors", keywords: "transparency"),
        Entry("Theme", .text, section: "Theme", keywords: "colors colours scheme palette dark light"),

        // Window
        Entry("Custom title:", .window, section: "Title", keywords: "window name"),
        Entry("Title components", .window, section: "Title", keywords: "working directory path process arguments shell tty dimensions profile name"),
        Entry("Window Size", .window, section: "Window Size", keywords: "columns rows dimensions"),
        Entry("Limit scrollback", .window, section: "Scrollback", keywords: "history lines buffer"),
        Entry("Scrollback lines:", .window, section: "Scrollback", keywords: "history buffer size count"),

        // Shell
        Entry("Run:", .shell, section: "Shell", keywords: "command login shell startup"),
        Entry("Command:", .shell, section: "Shell", keywords: "program run instead of shell htop ssh"),
        Entry("Run inside shell", .shell, section: "Shell"),
        Entry("When the shell exits:", .shell, section: "Shell", keywords: "close keep open"),
        Entry("Ask before closing:", .shell, section: "Shell", keywords: "confirm quit"),

        // Keyboard
        Entry("Use Option as Meta key", .keyboard, section: "Keys", keywords: "alt emacs"),
        Entry("Delete sends Control-H", .keyboard, section: "Keys", keywords: "backspace ^H"),
        Entry("Hide pointer while typing", .keyboard, section: "Keys", keywords: "mouse cursor"),
        Entry("Key Mappings", .keyboard, section: "Key Mappings", keywords: "shortcut binding escape sequence"),
        Entry("Shortcuts", .keyboard, section: "Shortcuts", keywords: "keyboard hotkeys keys list back forward tabs splits markdown browser palette"),

        // Advanced
        Entry("Declare terminal as:", .advanced, section: "Terminal", keywords: "TERM xterm ghostty TERM_PROGRAM TERM_VERSION"),
        Entry("TERM_PROGRAM:", .advanced, section: "Terminal", keywords: "ghostty identity environment"),
        Entry("TERM_VERSION:", .advanced, section: "Terminal", keywords: "ghostty identity environment"),
        Entry("Bell:", .advanced, section: "Terminal", keywords: "beep visual sound"),
        Entry("Environment", .advanced, section: "Environment", keywords: "variables env PATH"),

        // Updates
        Entry("When a new version is out:", .updates, section: "Updates", keywords: "automatic check updates sparkle version purple dot window notify"),
        Entry("Download and install updates automatically", .updates, section: "Updates"),
        Entry("Check for Updates Now", .updates, section: "Updates", keywords: "version new"),

        // Data
        Entry("Data", .data, section: "Data", keywords: "recovery backup reset preferences corrupt")
    ]
}
