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
    static let excludedTitles: Set<String> = [CommandPaletteModel.menuTitle, "Services", "Open Recent"]

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

    enum Item: Identifiable {
        case match(QuickSelectMatch)
        case command(PaletteCommand)

        var id: String {
            switch self {
            case .match(let match): return "match:\(match.kind.rawValue):\(match.text)"
            case .command(let command): return "command:\(command.id)"
            }
        }
    }

    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    let matches: [QuickSelectMatch]
    let commands: [PaletteCommand]

    init(matches: [QuickSelectMatch], commands: [PaletteCommand]) {
        self.matches = matches
        self.commands = commands
    }

    /// With nothing typed, on-screen matches come first. Once a query is
    /// typed, commands lead (titles starting with it first), so text printed
    /// on screen cannot take over a search for a command.
    var items: [Item] {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return matches.map(Item.match) + commands.map(Item.command)
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
        return shownCommands.map(Item.command) + shownMatches.map(Item.match)
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
