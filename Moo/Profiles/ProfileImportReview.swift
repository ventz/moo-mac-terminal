//
//  ProfileImportReview.swift
//  Moo
//
//  A .mooprofile is shared like a theme, but a profile is more than colors:
//  it can name the command a new window runs instead of the shell, set
//  environment variables, map keys to text that is typed into the shell,
//  and tell programs which terminal they run in. Importing one is reviewed:
//  those parts are listed verbatim, and the default keeps only the
//  appearance. Numbers are clamped so a file cannot ask for a window of a
//  million columns.
//

import Foundation

/// How much of an imported profile is kept
enum ProfileImportScope {
    /// Font, colors, theme and window settings; the shell, environment, key
    /// mappings and terminal identity return to their defaults
    case appearanceOnly
    /// Everything the file holds
    case everything
}

enum ProfileImportReview {
    /// The longest an item is shown in the review alert
    static let itemLimit = 300
    /// The most items listed before "and N more"
    static let shownItemLimit = 12

    /// The parts of a profile that can run something, or change what a
    /// program sees, written out for the user to read. Empty when the
    /// profile is appearance only. Every value is cleaned like a title, so
    /// the file cannot reword the alert that reviews it.
    static func items(in profile: TerminalProfile) -> [String] {
        let standard = TerminalProfile.standardValues
        var items: [String] = []
        if case .command(let command, let runInShell) = profile.shell {
            items.append("Runs instead of your shell\(runInShell ? " (inside it)" : ""): \(shown(command))")
        }
        for variable in profile.environmentVariables {
            if let value = variable.value {
                items.append("Sets \(shown(variable.name))=\(shown(value))")
            } else {
                items.append("Unsets \(shown(variable.name))")
            }
        }
        for binding in profile.keyBindings {
            let key = modifierSymbols(binding.modifiers) + shown(binding.key)
            let value = binding.action.usesValue ? ": \(shown(binding.value))" : ""
            items.append("Maps \(key) to \(binding.action.displayName.lowercased())\(value)")
        }
        if profile.termProgram != standard.termProgram {
            items.append("Sets TERM_PROGRAM=\(shown(profile.termProgram))")
        }
        if profile.termVersion != standard.termVersion {
            items.append("Sets TERM_VERSION=\(shown(profile.termVersion))")
        }
        return items
    }

    /// The profile with everything `items(in:)` lists returned to its
    /// default, keeping the rest
    static func appearanceOnly(_ profile: TerminalProfile) -> TerminalProfile {
        let standard = TerminalProfile.standardValues
        var result = profile
        result.shell = standard.shell
        result.environmentVariables = standard.environmentVariables
        result.keyBindings = standard.keyBindings
        result.termProgram = standard.termProgram
        result.termVersion = standard.termVersion
        return result
    }

    static func applying(_ scope: ProfileImportScope, to profile: TerminalProfile) -> TerminalProfile {
        switch scope {
        case .appearanceOnly: return appearanceOnly(profile)
        case .everything: return profile
        }
    }

    static let columnsAndRowsRange = 1...1_000
    static let scrollbackLimit = 1_000_000
    static let fontSizeRange = 4.0...288.0

    /// Numbers brought into ranges Moo can draw. Validation already refused
    /// zero, negative and non-finite values; this bounds the large ones.
    static func clamped(_ profile: TerminalProfile) -> TerminalProfile {
        var result = profile
        result.columns = min(max(profile.columns, columnsAndRowsRange.lowerBound), columnsAndRowsRange.upperBound)
        result.rows = min(max(profile.rows, columnsAndRowsRange.lowerBound), columnsAndRowsRange.upperBound)
        result.scrollbackLines = profile.scrollbackLines.map { min(max($0, 0), scrollbackLimit) }
        result.fontSize = min(max(profile.fontSize, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        return result
    }

    /// The alert's list: one line per item, capped.
    static func summary(of items: [String]) -> String {
        var lines = items.prefix(shownItemLimit).map { "• \($0)" }
        if items.count > shownItemLimit {
            lines.append("…and \(items.count - shownItemLimit) more")
        }
        return lines.joined(separator: "\n")
    }

    private static func shown(_ text: String) -> String {
        let cleaned = TerminalNotificationParser.clean(text, limit: itemLimit)
        return cleaned.isEmpty ? "\u{201C}\u{201D}" : cleaned
    }

    private static func modifierSymbols(_ modifiers: TerminalKeyModifiers) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}
