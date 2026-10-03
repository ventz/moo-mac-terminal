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
        guard let text = text(from: payload) else { return nil }
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

    /// The most of a payload that is read. SwiftTerm accepts an OSC of tens
    /// of megabytes, and everything past the title and body limits is thrown
    /// away anyway; splitting all of it into lines on the main thread is not.
    static let payloadLimit = 16_384

    /// The payload as text, nil when it is not UTF-8. One cut at the limit
    /// may split a character, so a long payload is decoded leniently.
    static func text(from payload: [UInt8]) -> String? {
        guard payload.count > payloadLimit else { return String(bytes: payload, encoding: .utf8) }
        return String(decoding: payload.prefix(payloadLimit), as: UTF8.self)
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

    /// Combining marks kept on one character. Real text needs two or three;
    /// thousands stacked on one letter ("Zalgo") draw over the lines around
    /// it and make every layout of the string slow.
    static let combiningMarkLimit = 4

    /// Control characters and bidirectional overrides become spaces,
    /// invisible format characters are dropped, runs of whitespace collapse,
    /// and the result is capped with an ellipsis. The overrides matter
    /// because this text lands in menus and banners, where a right-to-left
    /// override could disguise what a line says.
    ///
    /// Only the first `limit * 4` scalars are read, so the cost is bounded
    /// by the limit, not by the input: an OSC 2 title can be 65 MiB, and
    /// cleaning all of one took over a second on the main thread.
    static func clean(_ text: String, limit: Int) -> String {
        let scalarBudget = limit * 4
        var scalars = String.UnicodeScalarView()
        var read = 0
        var truncated = false
        var marks = 0
        for scalar in text.unicodeScalars {
            guard read < scalarBudget else {
                truncated = true
                break
            }
            read += 1
            let category = scalar.properties.generalCategory
            if category == .control || isBidiControl(scalar) {
                scalars.append(" ")
                marks = 0
            } else if category == .nonspacingMark || category == .enclosingMark {
                marks += 1
                if marks <= combiningMarkLimit { scalars.append(scalar) }
            } else if isInvisible(scalar) {
                continue
            } else {
                scalars.append(scalar)
                marks = 0
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard truncated || collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: return true
        default: return false
        }
    }

    /// Characters that draw nothing: zero-width spaces and joiners, the
    /// soft hyphen, tag characters, and the Hangul fillers that render as
    /// blank letters. They can hide text inside a name ("Moo" and "M\u{200B}oo"
    /// look alike) or make one look empty. The zero-width joiner and
    /// non-joiner stay (emoji such as 👩‍💻 and Persian words need them), and
    /// variation selectors are marks, not format characters, so ❤️ survives.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x200D: return false
        case 0x115F, 0x1160, 0x3164, 0xFFA0: return true
        default: return scalar.properties.generalCategory == .format
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

    /// Bounds on what a program can make Moo hold while it never sends `d=1`:
    /// identifiers, and UTF-8 bytes per title or body.
    private static let pendingLimit = 16
    static let partLimit = 4_096

    private var pending: [String: Pending] = [:]

    mutating func consume(_ payload: [UInt8]) -> TerminalNotification? {
        guard let text = TerminalNotificationParser.text(from: payload) else { return nil }
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
        case "title": entry.title = Self.appending(value, to: entry.title)
        case "body": entry.body = Self.appending(value, to: entry.body)
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

    /// `part` followed by as much of `value` as fits in `partLimit` bytes,
    /// cut between scalars. Only what fits is ever copied.
    private static func appending(_ value: String, to part: String) -> String {
        var room = partLimit - part.utf8.count
        guard room > 0 else { return part }
        var kept = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            room -= UTF8.width(scalar)
            guard room >= 0 else { break }
            kept.append(scalar)
        }
        return part + String(kept)
    }
}
