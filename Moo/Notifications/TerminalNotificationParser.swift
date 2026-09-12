//
//  TerminalNotificationParser.swift
//  Moo
//
//  Turns the notification escape sequences other terminals display into a
//  title and a body. Three dialects, because a program picks one by which
//  terminal it believes it is running in:
//
//    OSC 777 ; notify ; <title> ; <body>   Ghostty, urxvt  (Claude Code: "ghostty")
//    OSC 9 ; <message>                     iTerm2          (Claude Code: "iterm2")
//    OSC 99 ; <metadata> ; <payload>       kitty           (Claude Code: "kitty")
//
//  OSC 9 is shared with ConEmu, whose numeric subcommands are not
//  notifications — 9;4 is the progress bar SwiftTerm already draws — so a
//  payload that starts with a number and a semicolon is ignored.
//
//  Everything here was written by a program in the terminal. It is shown as
//  data: control characters are stripped and lengths are capped.
//

import Foundation

struct TerminalNotification: Equatable, Sendable {
    var title: String
    var body: String
}

enum TerminalNotificationParser {
    /// The OSC codes worth waking the main thread for. Nonisolated: it is
    /// checked on SwiftTerm's observer queue, before the hop to main.
    nonisolated static let observedCodes: Set<Int> = [9, 99, 777]

    static let titleLimit = 120
    static let bodyLimit = 400

    /// OSC 777 and OSC 9. kitty's OSC 99 arrives in pieces and goes through
    /// `KittyNotificationAssembler` instead.
    static func parse(code: Int, payload: [UInt8]) -> TerminalNotification? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        switch code {
        case 777: return parseNotify(text)
        case 9: return parseITerm2(text)
        default: return nil
        }
    }

    /// `notify;<title>;<body>`. The body is everything after the second
    /// separator, so a body containing semicolons survives intact.
    static func parseNotify(_ text: String) -> TerminalNotification? {
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "notify" else { return nil }
        return make(title: String(parts[1]), body: parts.count > 2 ? String(parts[2]) : "")
    }

    /// iTerm2 has no title field. A multi-line message is read as a heading
    /// line ("Claude Code:") followed by the text; a single line is all body.
    static func parseITerm2(_ text: String) -> TerminalNotification? {
        guard !isConEmuSubcommand(text) else { return nil }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        guard lines.count > 1 else { return make(title: "", body: first) }
        let title = first.hasSuffix(":") ? String(first.dropLast()) : first
        return make(title: title, body: lines.dropFirst().joined(separator: " "))
    }

    private static func isConEmuSubcommand(_ text: String) -> Bool {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = text.dropFirst(digits.count)
        return rest.isEmpty || rest.first == ";"
    }

    /// Cleans both fields; nil when nothing readable is left.
    static func make(title: String, body: String) -> TerminalNotification? {
        let title = clean(title, limit: titleLimit)
        let body = clean(body, limit: bodyLimit)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return TerminalNotification(title: title, body: body)
    }

    /// Control characters and bidirectional overrides become spaces, runs of
    /// whitespace collapse, and the result is capped with an ellipsis. The
    /// overrides matter because this text lands in menus and banners, where a
    /// right-to-left override could disguise what a line says.
    static func clean(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || isBidiControl(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: return true
        default: return false
        }
    }
}

/// kitty's OSC 99 sends one notification as several sequences sharing an
/// identifier: `i=1:d=0;Title`, then `i=1:p=body;Body`. `d=0` means more is
/// coming; a missing `d`, or `d=1`, completes it. `e=1` marks a base64 payload.
/// Parts other than the title and body (icons, buttons, queries) are not shown.
struct KittyNotificationAssembler {
    private struct Pending {
        var title = ""
        var body = ""
    }

    /// Bounds on what a program can make Moo hold while it never sends `d=1`.
    private static let pendingLimit = 16
    private static let partLimit = 4_096

    private var pending: [String: Pending] = [:]

    mutating func consume(_ payload: [UInt8]) -> TerminalNotification? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let metadata: Substring
        var value: String
        if let separator = text.firstIndex(of: ";") {
            metadata = text[..<separator]
            value = String(text[text.index(after: separator)...])
        } else {
            metadata = Substring(text)
            value = ""
        }

        var identifier = "0"
        var isDone = true
        var part = "title"
        var isBase64 = false
        for pair in metadata.split(separator: ":") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            switch keyValue[0] {
            case "i": identifier = String(keyValue[1])
            case "d": isDone = keyValue[1] != "0"
            case "p": part = String(keyValue[1])
            case "e": isBase64 = keyValue[1] == "1"
            default: break
            }
        }

        // A capability query must not complete, or discard, a notification.
        guard part != "?" else { return nil }

        if isBase64 {
            value = Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        var entry = pending[identifier] ?? Pending()
        switch part {
        case "title": entry.title = String((entry.title + value).prefix(Self.partLimit))
        case "body": entry.body = String((entry.body + value).prefix(Self.partLimit))
        default: break
        }

        guard isDone else {
            if pending[identifier] == nil, pending.count >= Self.pendingLimit {
                pending.removeAll()
            }
            pending[identifier] = entry
            return nil
        }
        pending[identifier] = nil
        return TerminalNotificationParser.make(title: entry.title, body: entry.body)
    }
}
