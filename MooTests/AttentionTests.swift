import AppKit
import Foundation
import os
import SwiftTerm
import Testing
@testable import Moo

@MainActor
final class TerminalNotificationParserTests {
    private func parse(_ code: Int, _ text: String) -> TerminalNotification? {
        TerminalNotificationParser.parse(code: code, payload: Array(text.utf8))
    }

    /// Claude Code's "ghostty" channel.
    @Test func notifyCarriesTitleAndBody() {
        #expect(parse(777, "notify;Claude Code;Claude is waiting for your input")
            == TerminalNotification(title: "Claude Code", body: "Claude is waiting for your input"))
    }

    @Test func notifyBodyKeepsItsSemicolons() {
        #expect(parse(777, "notify;Build;step 1; step 2")?.body == "step 1; step 2")
    }

    @Test func otherOSC777VerbsAreIgnored() {
        #expect(parse(777, "preexec;ls") == nil)
    }

    @Test func iTerm2SingleLineIsTheBody() {
        #expect(parse(9, "Build finished") == TerminalNotification(title: "", body: "Build finished"))
    }

    @Test func iTerm2HeadingLineBecomesTheTitle() {
        #expect(parse(9, "\n\nClaude Code:\nClaude is waiting for your input")
            == TerminalNotification(title: "Claude Code", body: "Claude is waiting for your input"))
    }

    /// OSC 9;4 is the progress bar SwiftTerm draws; it must never list as a
    /// notification.
    @Test func conEmuSubcommandsAreNotNotifications() {
        #expect(parse(9, "4;1;50") == nil)
        #expect(parse(9, "4;0") == nil)
        #expect(parse(9, "12") == nil)
    }

    @Test func controlAndBidirectionalCharactersAreRemoved() {
        let parsed = parse(777, "notify;Red\u{1b}[31mTitle;left\u{202E}right")
        #expect(parsed?.title == "Red [31mTitle")
        #expect(parsed?.body == "left right")
    }

    @Test func longTextIsCapped() {
        let parsed = parse(777, "notify;T;" + String(repeating: "x", count: 1_000))
        #expect(parsed?.body.count == TerminalNotificationParser.bodyLimit)
        #expect(parsed?.body.hasSuffix("…") == true)
    }

    @Test func emptyNotificationsAreIgnored() {
        #expect(parse(777, "notify; ;") == nil)
        #expect(parse(9, "\n\n") == nil)
    }

    @Test func unrelatedCodesAreIgnored() {
        #expect(parse(52, "c;aGVsbG8=") == nil)
    }
}

@MainActor
final class KittyNotificationAssemblerTests {
    private func consume(_ assembler: inout KittyNotificationAssembler, _ text: String) -> TerminalNotification? {
        assembler.consume(Array(text.utf8))
    }

    @Test func assemblesTitleAndBodyAcrossSequences() {
        var assembler = KittyNotificationAssembler()
        #expect(consume(&assembler, "i=7:d=0:p=title;Claude Code") == nil)
        #expect(consume(&assembler, "i=7:p=body;Waiting")
            == TerminalNotification(title: "Claude Code", body: "Waiting"))
        // A trailing, empty focus request completes nothing further.
        #expect(consume(&assembler, "i=7:d=1:a=focus;") == nil)
    }

    @Test func aSingleSequenceIsATitle() {
        var assembler = KittyNotificationAssembler()
        #expect(consume(&assembler, "i=1;Done") == TerminalNotification(title: "Done", body: ""))
    }

    @Test func decodesBase64Payloads() {
        var assembler = KittyNotificationAssembler()
        let encoded = Data("Hello".utf8).base64EncodedString()
        #expect(consume(&assembler, "i=2:e=1;\(encoded)")?.title == "Hello")
    }

    @Test func queriesNeitherCompleteNorDiscard() {
        var assembler = KittyNotificationAssembler()
        #expect(consume(&assembler, "i=3:d=0;Title") == nil)
        #expect(consume(&assembler, "i=3:p=?;") == nil)
        #expect(consume(&assembler, "i=3;")?.title == "Title")
    }

    @Test func identifiersDoNotMix() {
        var assembler = KittyNotificationAssembler()
        #expect(consume(&assembler, "i=a:d=0;First") == nil)
        #expect(consume(&assembler, "i=b:d=0;Second") == nil)
        #expect(consume(&assembler, "i=a:p=body;one") == TerminalNotification(title: "First", body: "one"))
        #expect(consume(&assembler, "i=b:p=body;two") == TerminalNotification(title: "Second", body: "two"))
    }
}

@MainActor
final class AttentionCenterTests {
    private let waiting = TerminalNotification(title: "Claude Code", body: "Claude is waiting for your input")
    private let permission = TerminalNotification(title: "Claude Code", body: "Claude needs your permission")

    private func makeCenter() -> AttentionCenter {
        AttentionCenter(integratesWithSystem: false)
    }

    @Test func recordAddsUnreadEntriesNewestFirst() {
        let center = makeCenter()
        let first = center.record(waiting, surfaceID: UUID(), location: "One")
        let second = center.record(waiting, surfaceID: UUID(), location: "Two")
        #expect(center.items.map(\.id) == [second.id, first.id])
        #expect(center.unreadCount == 2)
        #expect(center.latestUnread?.id == second.id)
    }

    /// Agents repeat "waiting" while they wait; the list must not fill with it.
    @Test func aRepeatFromThePaneRefreshesInsteadOfStacking() {
        let center = makeCenter()
        let pane = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = center.record(waiting, surfaceID: pane, location: "Tab", now: start)
        center.record(waiting, surfaceID: UUID(), location: "Other")
        let repeated = center.record(waiting, surfaceID: pane, location: "Tab", now: start.addingTimeInterval(60))
        #expect(repeated.id == first.id)
        #expect(center.items.count == 2)
        #expect(center.items.first?.id == first.id)
        #expect(center.items.first?.date == start.addingTimeInterval(60))
    }

    @Test func aDifferentMessageFromThePaneStacks() {
        let center = makeCenter()
        let pane = UUID()
        center.record(waiting, surfaceID: pane, location: "Tab")
        center.record(permission, surfaceID: pane, location: "Tab")
        #expect(center.items.count == 2)
    }

    @Test func lookingAtAPaneReadsOnlyItsEntries() {
        let center = makeCenter()
        let pane = UUID()
        let other = UUID()
        center.record(waiting, surfaceID: pane, location: "Tab")
        center.record(permission, surfaceID: pane, location: "Tab")
        center.record(waiting, surfaceID: other, location: "Other")

        center.markRead(surfaceID: pane)
        #expect(center.unreadCount == 1)
        #expect(center.unreadItems(from: [pane]).isEmpty)
        #expect(center.unreadItems(from: [other]).count == 1)
    }

    /// Once read, the same words mean the agent is waiting again.
    @Test func aRepeatAfterReadingIsANewEntry() {
        let center = makeCenter()
        let pane = UUID()
        center.record(waiting, surfaceID: pane, location: "Tab")
        center.markRead(surfaceID: pane)
        center.record(waiting, surfaceID: pane, location: "Tab")
        #expect(center.items.count == 2)
        #expect(center.unreadCount == 1)
    }

    @Test func historyIsCapped() {
        let center = makeCenter()
        for index in 0..<(AttentionCenter.historyLimit + 10) {
            center.record(
                TerminalNotification(title: "T", body: "message \(index)"),
                surfaceID: UUID(),
                location: ""
            )
        }
        #expect(center.items.count == AttentionCenter.historyLimit)
        #expect(center.items.first?.body == "message \(AttentionCenter.historyLimit + 9)")
    }

    @Test func markAllReadThenClearAll() {
        let center = makeCenter()
        center.record(waiting, surfaceID: UUID(), location: "")
        center.record(permission, surfaceID: UUID(), location: "")
        center.markAllRead()
        #expect(center.unreadCount == 0)
        #expect(center.items.count == 2)
        #expect(center.dockBadgeLabel == nil)
        center.clearAll()
        #expect(center.items.isEmpty)
    }

    @Test func closingAPaneRemovesItsEntries() {
        let center = makeCenter()
        let pane = UUID()
        center.record(waiting, surfaceID: pane, location: "")
        center.record(waiting, surfaceID: UUID(), location: "")
        center.removeItems(from: pane)
        #expect(center.items.count == 1)
        #expect(center.dockBadgeLabel == "1")
    }

    @Test func waitingOutranksEveryOtherStatus() {
        #expect(ProjectStatus.waiting > ProjectStatus.attention)
    }
}

/// The shared center against a real workspace: what the sidebar reports, and
/// where an entry leads. startsProcesses: false, so no shells are spawned.
@MainActor
@Suite(.serialized)
final class AttentionWorkspaceTests {
    @Test func anUnreadNotificationMakesTheProjectWaitingUntilItsPaneIsRead() throws {
        let center = AttentionCenter.shared
        center.clearAll()
        defer { center.clearAll() }

        let runtime = ProjectRuntime(startsProcesses: false)
        let projectID = UUID()
        let session = runtime.session(for: projectID)
        session.ensureTab()
        let background = session.addTab()
        let controller = try #require(background.controllers.first)
        runtime.invalidate()
        #expect(runtime.status(for: projectID).status != .waiting)

        center.record(
            TerminalNotification(title: "Claude Code", body: "Claude is waiting for your input"),
            surfaceID: controller.id,
            location: "Project › Tab"
        )
        runtime.invalidate()
        let report = runtime.status(for: projectID)
        #expect(report.status == .waiting)
        #expect(report.source == .notification)
        #expect(report.message == "Claude is waiting for your input")

        center.markRead(surfaceID: controller.id)
        runtime.invalidate()
        #expect(runtime.status(for: projectID).status != .waiting)
    }

    @Test func aControllerResolvesToItsProjectAndTab() throws {
        let runtime = ProjectRuntime(startsProcesses: false)
        let projectID = UUID()
        let session = runtime.session(for: projectID)
        session.ensureTab()
        let second = session.addTab()
        let controller = try #require(second.controllers.first)

        let location = try #require(runtime.location(of: controller))
        #expect(location.projectID == projectID)
        #expect(location.tab.id == second.id)
        #expect(runtime.location(of: TerminalSessionController(startsProcess: false)) == nil)
    }
}

/// Settings are read from a throwaway defaults suite, never the app's own.
@MainActor
final class AttentionAlertSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "AttentionAlertSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func item(body: String, location: String) -> AttentionItem {
        AttentionItem(
            id: UUID(), surfaceID: UUID(), date: Date(),
            title: "Claude Code", body: body, location: location, isRead: false
        )
    }

    /// Must agree with the @AppStorage defaults in NotificationsSettingsView.
    @Test func nothingStoredMeansTheDocumentedDefaults() throws {
        let settings = AttentionAlertSettings(defaults: try makeDefaults())
        #expect(settings == AttentionAlertSettings())
        #expect(settings.dockBounce == .once)
        #expect(settings.sound == "Glass")
        #expect(settings.volume == 1)
        #expect(settings.audioTiming == .always)
        #expect(!settings.speaksMessage)
    }

    @Test func storedChoicesAreRead() throws {
        let defaults = try makeDefaults()
        defaults.set("untilActive", forKey: AttentionDefaults.dockBounce)
        defaults.set("Submarine", forKey: AttentionDefaults.sound)
        defaults.set(0.25, forKey: AttentionDefaults.soundVolume)
        defaults.set("inBackground", forKey: AttentionDefaults.audioTiming)
        defaults.set(true, forKey: AttentionDefaults.speaksMessage)

        let settings = AttentionAlertSettings(defaults: defaults)
        #expect(settings.dockBounce == .untilActive)
        #expect(settings.sound == "Submarine")
        #expect(settings.volume == 0.25)
        #expect(settings.audioTiming == .inBackground)
        #expect(settings.speaksMessage)
    }

    @Test func unknownAndOutOfRangeValuesFallBack() throws {
        let defaults = try makeDefaults()
        defaults.set("sideways", forKey: AttentionDefaults.dockBounce)
        defaults.set(3.0, forKey: AttentionDefaults.soundVolume)
        defaults.set("sometimes", forKey: AttentionDefaults.audioTiming)

        let settings = AttentionAlertSettings(defaults: defaults)
        #expect(settings.dockBounce == .once)
        #expect(settings.volume == 1)
        #expect(settings.audioTiming == .always)
    }

    @Test func noneMeansNoSound() throws {
        let defaults = try makeDefaults()
        defaults.set(AttentionAlertSettings.noSound, forKey: AttentionDefaults.sound)
        #expect(!AttentionAlertSettings(defaults: defaults).playsSound)
    }

    @Test func backgroundTimingOnlyPlaysWhileInactive() {
        var settings = AttentionAlertSettings()
        #expect(settings.playsAudio(appIsActive: true))
        settings.audioTiming = .inBackground
        #expect(!settings.playsAudio(appIsActive: true))
        #expect(settings.playsAudio(appIsActive: false))
    }

    /// The tab half of a location is often a spinner title; it is not read out.
    @Test func spokenTextNamesTheProjectNotTheTab() {
        #expect(AttentionAlertSettings.spokenText(for: item(body: "Waiting", location: "home › ✳ Refactor"))
            == "home: Waiting")
        #expect(AttentionAlertSettings.spokenText(for: item(body: "", location: ""))
            == "Claude Code")
    }

    @Test func systemSoundsAreOffered() {
        #expect(AttentionAlertSettings.availableSounds().contains(AttentionAlertSettings.defaultSound))
    }
}

@MainActor
final class TerminalNotificationObservationTests {
    /// The observer lives on SwiftTerm's internal `Terminal`, reached by
    /// reflection. If a SwiftTerm update renames that property, notifications
    /// would silently stop; this fails instead.
    @Test func appTerminalViewReachesItsEngine() {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(view.terminalEngine != nil)
    }

    @Test func aNotifySequenceReachesTheObserver() async throws {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let engine = try #require(view.terminalEngine)
        let seen = OSAllocatedUnfairLock<[TerminalOscEvent]>(initialState: [])
        let observation = engine.observeOscEvents { event in
            seen.withLock { $0.append(event) }
        }
        defer { observation.cancel() }

        view.feed(text: "\u{1b}]777;notify;Claude Code;Waiting\u{07}")
        for _ in 0..<100 where seen.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let event = try #require(seen.withLock { $0.first })
        #expect(TerminalNotificationParser.parse(code: event.code, payload: event.payload)
            == TerminalNotification(title: "Claude Code", body: "Waiting"))
    }
}
