//
//  CommandStatus.swift
//  Moo
//
//  How the last command in a pane ended, from OSC 133 shell integration:
//  `C` marks the command starting, `D;<exit>` its end. SwiftTerm keeps only
//  the row kinds from these marks and drops the exit code, so Moo reads the
//  raw sequence off the OSC observer, like notifications.
//
//  Terminal output can forge the marks, so nothing here trusts their text:
//  duration comes from Moo's clock, a `D` counts only after a `C`, and the
//  notification wording is Moo's own.
//

import Foundation

struct CommandCompletion: Equatable {
    /// nil when the shell sent `D` without a status.
    var exitCode: Int32?
    var duration: TimeInterval

    /// Exit statuses that are not worth a red mark: ctrl+C (128 + SIGINT) is
    /// the user's own doing, and SIGPIPE (141) is `yes | head` working.
    static let unremarkableExitCodes: Set<Int32> = [0, 130, 141]

    var failed: Bool {
        guard let exitCode else { return false }
        return !Self.unremarkableExitCodes.contains(exitCode)
    }
}

/// One clock per pane. A shell started inside another sends its own `C`,
/// which restarts the clock: the latest command wins, and the outer command
/// (the subshell itself) is not reported when it ends. `ssh` without remote
/// shell integration sends no marks from the far side, so it times normally.
struct CommandTracker {
    nonisolated static let oscCode = 133
    /// Real marks are a few bytes ("D;1;aid=123"); anything longer is ignored.
    nonisolated static let payloadLimit = 256

    private var startedAt: Date?

    /// Feeds one OSC 133 payload; returns a completion when a command ends.
    mutating func consume(_ payload: String, now: Date = Date()) -> CommandCompletion? {
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        switch fields.first {
        case "C":
            startedAt = now
            return nil
        case "D":
            guard let startedAt else { return nil }
            self.startedAt = nil
            let exitCode = fields.count > 1 ? Int32(fields[1]) : nil
            return CommandCompletion(exitCode: exitCode, duration: max(0, now.timeIntervalSince(startedAt)))
        default:
            return nil
        }
    }
}

/// Decides whether a finished command is worth a notification, at most one
/// per pane every few seconds so a script printing marks cannot flood.
struct LongCommandNotifier {
    static let minimumInterval: TimeInterval = 5

    private var lastPostedAt: Date?

    mutating func notification(
        for completion: CommandCompletion,
        threshold: TimeInterval,
        now: Date = Date()
    ) -> TerminalNotification? {
        guard completion.duration >= threshold else { return nil }
        if let lastPostedAt, now.timeIntervalSince(lastPostedAt) < Self.minimumInterval {
            return nil
        }
        lastPostedAt = now
        let title: String
        if completion.failed, let code = completion.exitCode {
            title = "Command failed (exit \(code))"
        } else {
            title = "Command finished"
        }
        return TerminalNotification(title: title, body: "Took \(Self.format(completion.duration))")
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) m \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds / 60 % 60) m"
    }
}
