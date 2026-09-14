import Foundation
import Testing
@testable import Moo

final class CommandStatusTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func completionNeedsAStartMark() {
        var tracker = CommandTracker()
        #expect(tracker.consume("D;1", now: start) == nil)
        #expect(tracker.consume("A", now: start) == nil)
        #expect(tracker.consume("C", now: start) == nil)
        #expect(tracker.consume("D;2", now: start.addingTimeInterval(42))
            == CommandCompletion(exitCode: 2, duration: 42))
        // A second D without a new C is ignored.
        #expect(tracker.consume("D;0", now: start.addingTimeInterval(50)) == nil)
    }

    @Test func missingOrOddStatusIsNotAFailure() {
        var tracker = CommandTracker()
        _ = tracker.consume("C", now: start)
        let bare = tracker.consume("D", now: start)
        #expect(bare?.exitCode == nil)
        #expect(bare?.failed == false)
        _ = tracker.consume("C", now: start)
        #expect(tracker.consume("D;aid=7", now: start)?.exitCode == nil)
        #expect(!CommandCompletion(exitCode: 130, duration: 1).failed)
        #expect(!CommandCompletion(exitCode: 0, duration: 1).failed)
        #expect(CommandCompletion(exitCode: 1, duration: 1).failed)
    }

    @Test func onlyLongCommandsNotifyAndAtMostOnceEveryFewSeconds() {
        var notifier = LongCommandNotifier()
        let quick = CommandCompletion(exitCode: 0, duration: 3)
        let long = CommandCompletion(exitCode: 1, duration: 75)
        #expect(notifier.notification(for: quick, threshold: 10, now: start) == nil)
        #expect(notifier.notification(for: long, threshold: 10, now: start)
            == TerminalNotification(title: "Command failed (exit 1)", body: "Took 1 m 15 s"))
        #expect(notifier.notification(for: long, threshold: 10, now: start.addingTimeInterval(2)) == nil)
        #expect(notifier.notification(for: long, threshold: 10, now: start.addingTimeInterval(6)) != nil)
    }

    /// What Moo's integrations actually send.
    @Test func eachShellsMarksAreUnderstood() {
        var tracker = CommandTracker()
        // bash: "C;" then "D;<status>;aid=<pid>"
        _ = tracker.consume("C;", now: start)
        #expect(tracker.consume("D;0;aid=4242", now: start.addingTimeInterval(1))?.exitCode == 0)
        // zsh and fish: a bare D at the next prompt, after the real one
        #expect(tracker.consume("D", now: start.addingTimeInterval(2)) == nil)
        // elvish: "D;aid=" at a prompt with no command
        #expect(tracker.consume("D;aid=1", now: start.addingTimeInterval(3)) == nil)
    }

    @Test func aNestedShellsCommandWins() {
        var tracker = CommandTracker()
        _ = tracker.consume("C", now: start)                       // `zsh`
        _ = tracker.consume("C", now: start.addingTimeInterval(5)) // `make` inside it
        #expect(tracker.consume("D;2", now: start.addingTimeInterval(8))
            == CommandCompletion(exitCode: 2, duration: 3))
        #expect(tracker.consume("D;0", now: start.addingTimeInterval(9)) == nil)
    }

    @Test func brokenPipesAreNotFailures() {
        #expect(!CommandCompletion(exitCode: 141, duration: 1).failed)
        #expect(CommandCompletion(exitCode: 137, duration: 1).failed)
    }

    @Test func thresholdDefaultsAndClamps() {
        let suite = "CommandStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AttentionDefaults.longCommandThreshold(in: defaults) == AttentionDefaults.defaultLongCommandSeconds)
        #expect(AttentionDefaults.defaultLongCommandSeconds == 10)
        #expect(AttentionDefaults.defaultNotifiesLongCommands)
        #expect(AttentionDefaults.defaultMarksFailedCommands)
        defaults.set(0.0, forKey: AttentionDefaults.longCommandSeconds)
        #expect(AttentionDefaults.longCommandThreshold(in: defaults) == 1)
    }

    @Test func durationsReadNaturally() {
        #expect(LongCommandNotifier.format(9.6) == "10 s")
        #expect(LongCommandNotifier.format(3_725) == "1 h 2 m")
    }
}
