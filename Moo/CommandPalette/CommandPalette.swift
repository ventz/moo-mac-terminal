//
//  CommandPalette.swift
//  Moo
//
//  Command-K: one list for everything. Typing filters two kinds of item:
//  what is on screen worth grabbing (links, paths, commit hashes, IP
//  addresses) and every command in the menu bar. Commands are read from the
//  menus rather than listed by hand, so the palette never offers something
//  the menus do not, or runs it any differently.
//
//  The screen is read once, when the palette opens. Nothing here runs while
//  output is arriving.
//

import AppKit
import Foundation

struct QuickSelectMatch: Hashable {
    enum Kind: String {
        case url = "Link"
        case path = "Path"
        case hash = "Hash"
        case address = "Address"
    }

    let kind: Kind
    let text: String
}

enum QuickSelectMatcher {
    static let limit = 40
    /// Longer rows are cut before matching. Terminal rows are a few hundred
    /// cells; the cap only bounds a pathological one.
    static let rowLimit = 1_000

    /// In priority order: a later kind never matches inside an earlier one's
    /// text, so a hash in a path or an address in a link is not offered twice.
    /// Possessive quantifiers keep a long row from backtracking for seconds.
    private static let patterns: [(QuickSelectMatch.Kind, NSRegularExpression)] = [
        (.url, #"\b[a-zA-Z][a-zA-Z0-9+.-]*+://[^\s<>"'`]++|\bmailto:[^\s<>"'`]++"#),
        (.path, #"(?:~|\.{1,2}|[\w.-]++)?/[^\s<>"'`|;]++"#),
        (.address, #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#),
        (.hash, #"\b[0-9a-f]{7,40}\b"#)
    ].map { kind, pattern in
        // Literal patterns: a failure here is a programming error.
        (kind, try! NSRegularExpression(pattern: pattern))
    }

    /// Matches from the bottom row up — the newest output first — and left
    /// to right within a row, without repeats.
    static func matches(inRows rows: [String]) -> [QuickSelectMatch] {
        var seen = Set<String>()
        var found: [QuickSelectMatch] = []
        for fullRow in rows.reversed() {
            let row = String(fullRow.prefix(rowLimit))
            let text = row as NSString
            var claimed: [NSRange] = []
            var inRow: [(location: Int, match: QuickSelectMatch)] = []
            for (kind, regex) in patterns {
                for result in regex.matches(in: row, range: NSRange(location: 0, length: text.length)) {
                    guard !claimed.contains(where: { NSIntersectionRange($0, result.range).length > 0 }) else {
                        continue
                    }
                    var value = text.substring(with: result.range)
                    switch kind {
                    case .url, .path:
                        value = trimmed(value)
                        guard value.count >= 3 else { continue }
                    case .hash:
                        guard isLikelyHash(value) else { continue }
                    case .address:
                        break
                    }
                    claimed.append(result.range)
                    inRow.append((result.range.location, QuickSelectMatch(kind: kind, text: sanitized(value))))
                }
            }
            for entry in inRow.sorted(by: { $0.location < $1.location })
            where seen.insert(entry.match.text).inserted {
                found.append(entry.match)
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// A hash has digits and letters; "deadbeef" and "20260913" are words
    /// and numbers.
    static func isLikelyHash(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }

    /// Sentence punctuation that follows a link or path in prose.
    static func trimmed(_ text: String) -> String {
        var value = Substring(text)
        while let last = value.last, ".,;:!?)]}'\"".contains(last) {
            value.removeLast()
        }
        return String(value)
    }

    /// Drops control and formatting characters, bidi overrides included, so
    /// what is copied is exactly what was shown.
    static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

enum QuickSelectAction {
    /// Clipboard managers skip items carrying this type.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// A link with a user or password in it is copied as concealed too.
    static func carriesCredentials(_ match: QuickSelectMatch) -> Bool {
        guard match.kind == .url, let components = URLComponents(string: match.text) else { return false }
        return components.user != nil || components.password != nil
    }

    static func copy(_ match: QuickSelectMatch, concealed: Bool, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(match.text, forType: .string)
        if concealed {
            pasteboard.setData(Data(), forType: concealedType)
        }
    }
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    /// Where it lives, such as "Terminal" or "Window › Select Split".
    let path: String
    let shortcut: String
    let run: @MainActor () -> Void
}

@MainActor
enum MenuCommandCollector {
    /// Never offered: the palette itself, and menus of system or changing
    /// content.
    static let excludedTitles: Set<String> = [CommandPaletteModel.menuTitle, CommandPaletteModel.jumpMenuTitle, "Services", "Open Recent"]

    static func commands(in menu: NSMenu?) -> [PaletteCommand] {
        guard let menu else { return [] }
        var result: [PaletteCommand] = []
        collect(menu, path: [], into: &result)
        return result
    }

    private static func collect(_ menu: NSMenu, path: [String], into result: inout [PaletteCommand]) {
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            // The application menu's item has no title of its own.
            let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
            guard !title.isEmpty, !excludedTitles.contains(title) else { continue }
            if let submenu = item.submenu {
                collect(submenu, path: path + [title], into: &result)
                continue
            }
            // Window list entries come and go; they are not commands. An
            // alternate item is the option-key twin of the one before it.
            guard item.isEnabled, !item.isAlternate,
                  let action = item.action,
                  action != #selector(NSWindow.makeKeyAndOrderFront(_:)) else { continue }
            // The item itself is kept, not its place in the menu: SwiftUI can
            // rebuild the menus between the palette closing and this running.
            let command = PaletteCommand(
                id: (path + [title]).joined(separator: " › ") + "#\(result.count)",
                title: title,
                path: path.joined(separator: " › "),
                shortcut: shortcutText(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            ) { [item] in
                NSApp.sendAction(action, to: item.target, from: item)
            }
            result.append(command)
        }
    }

    static func shortcutText(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName(key)
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first.map({ Int($0.value) }) else { return "" }
        switch scalar {
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(scalar - NSF1FunctionKey + 1)"
        default: return key.uppercased()
        }
    }
}

enum PaletteFilter {
    /// Every word typed must appear, in any order.
    static func accepts(_ text: String, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }
}

@Observable
@MainActor
final class CommandPaletteModel {
    static let menuTitle = "Command Palette…"
    static let jumpMenuTitle = "Jump to Directory…"
    /// Typed first, these narrow the list, as in a launcher.
    static let directoryPrefix = "z "
    static let placePrefix = "t "
    /// Directories are many (zsh-z keeps hundreds); a list longer than this
    /// is only noise.
    static let directoryLimit = 30

    enum Item: Identifiable {
        case match(QuickSelectMatch)
        case command(PaletteCommand)
        case place(PalettePlace)
        case directory(PaletteDirectory)

        var id: String {
            switch self {
            case .match(let match): return "match:\(match.kind.rawValue):\(match.text)"
            case .command(let command): return "command:\(command.id)"
            case .place(let place): return "place:\(place.id)"
            case .directory(let directory): return "directory:\(directory.path)"
            }
        }
    }

    enum Narrowing: Equatable {
        case everything
        case directories
        case places
    }

    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    let matches: [QuickSelectMatch]
    let commands: [PaletteCommand]
    let places: [PalettePlace]
    let directories: [PaletteDirectory]
    /// Checked only for the directories about to be shown: a stale entry
    /// is dropped without a stat of every path zsh-z remembers.
    @ObservationIgnored private let directoryExists: (String) -> Bool
    @ObservationIgnored private var existence: [String: Bool] = [:]
    @ObservationIgnored private let resolvePath: (String) -> String?
    @ObservationIgnored private var realPaths: [String: String] = [:]

    init(matches: [QuickSelectMatch],
         commands: [PaletteCommand],
         places: [PalettePlace] = [],
         directories: [PaletteDirectory] = [],
         directoryExists: @escaping (String) -> Bool = CommandPaletteModel.isDirectory,
         resolvePath: @escaping (String) -> String? = { DirectoryPaths.resolved($0) }) {
        self.matches = matches
        self.commands = commands
        self.places = places
        self.directories = directories
        self.directoryExists = directoryExists
        self.resolvePath = resolvePath
    }

    nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The narrowing a prefix asks for, and the words after it.
    static func parse(_ query: String) -> (Narrowing, String) {
        let leading = String(query.drop(while: \.isWhitespace))
        for (prefix, narrowing) in [(directoryPrefix, Narrowing.directories), (placePrefix, .places)]
        where leading.lowercased().hasPrefix(prefix) {
            return (narrowing, leading.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        return (.everything, leading.trimmingCharacters(in: .whitespaces))
    }

    /// The words of the query, after any prefix.
    var searchWords: String { Self.parse(query).1 }

    var narrowing: Narrowing { Self.parse(query).0 }

    /// ⌘K opens as a tab list, like zsh's ⌃R (user, 2026-11-06): with
    /// nothing typed, every other tab, last used first, then what is on
    /// screen, then commands. Typing filters the tabs without reordering
    /// them, and they lead: tabs whose title starts with the query, then
    /// commands whose title does, then the other tabs and commands, then
    /// directories, then what is on screen. Text printed on screen cannot
    /// take over a search for a tab or a command.
    var items: [Item] {
        let (narrowing, query) = Self.parse(self.query)
        switch narrowing {
        case .directories:
            return shownDirectories(query).map(Item.directory)
        case .places:
            return pickerPlaces(query).map(Item.place)
        case .everything:
            guard !query.isEmpty else {
                return pickerPlaces("").map(Item.place)
                    + matches.map(Item.match)
                    + commands.map(Item.command)
            }
            let shownMatches = matches.filter { PaletteFilter.accepts($0.text, query: query) }
            let shownCommands = commands.enumerated()
                .filter { PaletteFilter.accepts("\($0.element.path) \($0.element.title)", query: query) }
                .sorted { lhs, rhs in
                    let left = lhs.element.title.lowercased().hasPrefix(query.lowercased())
                    let right = rhs.element.title.lowercased().hasPrefix(query.lowercased())
                    return left != right ? left : lhs.offset < rhs.offset
                }
                .map(\.element)
            // A command whose title starts with the query leads any tab that
            // does not: a tab's title is a program's to set, and a pane named
            // "Close Tab" must not push the real command down.
            let lowered = query.lowercased()
            let places = pickerPlaces(query)
            let leadingPlaces = places.filter { $0.title.lowercased().hasPrefix(lowered) }
            let otherPlaces = places.filter { !$0.title.lowercased().hasPrefix(lowered) }
            let leadingCommands = shownCommands.prefix { $0.title.lowercased().hasPrefix(lowered) }
            return leadingPlaces.map(Item.place)
                + leadingCommands.map(Item.command)
                + otherPlaces.map(Item.place)
                + shownCommands.dropFirst(leadingCommands.count).map(Item.command)
                + shownDirectories(query).map(Item.directory)
                + shownMatches.map(Item.match)
        }
    }

    /// The tab list, like zsh's ⌃R: every tab, the one used most recently
    /// first (so ↩ on the first row goes back to the tab just left), typing
    /// only filters and never reorders. The tab on screen is left out.
    /// Workspaces appear only when none of their tabs is open yet; an open
    /// workspace is found through its tabs, whose search text holds its name.
    private func pickerPlaces(_ query: String) -> [PalettePlace] {
        places.enumerated()
            .filter { !$0.element.isCurrent }
            .filter { $0.element.kind != .workspace || !$0.element.hasOpenTabs }
            .filter { query.isEmpty || PaletteFilter.accepts($0.element.searchText, query: query) }
            .sorted { lhs, rhs in
                lhs.element.lastUsed != rhs.element.lastUsed
                    ? lhs.element.lastUsed > rhs.element.lastUsed
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }


    /// As zsh-z ranks a `z` query: every word must appear in the path, best
    /// frecency first, except that a directory whose own name holds the
    /// last word leads (`z moo` prefers …/moo-mac-terminal to …/moo/docs).
    private func shownDirectories(_ query: String) -> [PaletteDirectory] {
        let last = query.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let candidates = directories.enumerated()
            .filter { query.isEmpty || PaletteFilter.accepts($0.element.path, query: query) }
            .sorted { lhs, rhs in
                let left = last.isEmpty || lhs.element.leaf.localizedStandardContains(last)
                let right = last.isEmpty || rhs.element.leaf.localizedStandardContains(last)
                return left != right ? left : lhs.offset < rhs.offset
            }
            .map(\.element)
        var shown: [PaletteDirectory] = []
        var seen: Set<String> = []
        for directory in candidates {
            if shown.count == Self.directoryLimit { break }
            // One row per real directory: Moo records the kernel's path
            // (/private/var/…), zsh-z the shell's (/var/…, or through a
            // symlink). The first, higher-ranked, spelling stays.
            guard exists(directory.path), seen.insert(realPath(directory.path)).inserted else { continue }
            shown.append(directory)
        }
        return shown
    }

    private func realPath(_ path: String) -> String {
        if let known = realPaths[path] { return known }
        let resolved = path.hasPrefix("/Volumes/") || path.hasPrefix("/net/")
            ? path : (resolvePath(path) ?? path)
        realPaths[path] = resolved
        return resolved
    }

    private func exists(_ path: String) -> Bool {
        if let known = existence[path] { return known }
        // Network and removable volumes can stall a stat; offer them and
        // let the jump find out.
        let found = path.hasPrefix("/Volumes/") || path.hasPrefix("/net/") || directoryExists(path)
        existence[path] = found
        return found
    }

    var selectedItem: Item? {
        let items = items
        return items.indices.contains(selection) ? items[selection] : nil
    }

    func moveSelection(by offset: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + offset % count + count) % count
    }
}
