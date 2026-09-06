//
//  MarkdownPreviewCommands.swift
//  Tecolot
//
//  The ways a preview tab comes to exist — a menu command, a click on a
//  markdown path in the terminal, an AppleScript call — and the menu items
//  that act on one.
//

import AppKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum MarkdownPreviewOpener {
    /// Hooks the feature into the link router. Called once at launch.
    static func install() {
        LinkRouter.openMarkdownPreview = { url, controller in
            open(fileURL: url, from: controller)
        }
    }

    /// Opens a preview tab in the selected workspace, or brings an existing
    /// preview of the same file to the front. Returns false when there is no
    /// workspace to put a tab in, so the caller can fall back to the system.
    @discardableResult
    static func open(fileURL: URL, from controller: TerminalSessionController?) -> Bool {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession else { return false }
        let standardized = fileURL.standardizedFileURL

        if let existing = session.tabs.first(where: { tab in
            (tab.web as? MarkdownPreviewSession)?.fileURL == standardized
        }) {
            session.select(existing)
            runtime.invalidate()
            return true
        }

        session.addTab(web: MarkdownPreviewSession(fileURL: standardized))
        runtime.invalidate()
        return true
    }

    /// The menu command: pick a file, then preview it.
    static func openFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = LinkRouter.markdownExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Markdown file to preview"
        if let directory = ProjectRuntime.shared.selectedProjectID
            .flatMap({ ProjectRuntime.shared.currentDirectory(for: $0) }) {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(fileURL: url, from: nil)
    }

    /// The preview's "Run" button: types a shell block into the workspace's
    /// most recent terminal and brings it to the front — and stops there.
    /// Nothing is executed: the text lands at the prompt for the user to
    /// read and confirm with Return, because a code block can hide what it
    /// really contains (text scrolled off to the right, bidi overrides, a
    /// line below the fold). A multi-line block goes through the terminal's
    /// own paste path, which honours bracketed paste, so the shell shows it
    /// as one pasted unit instead of running every line but the last.
    static func run(command: String, from preview: MarkdownPreviewSession) {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession,
              let terminalTab = session.mostRecentTerminalTab,
              let controller = terminalTab.panes?.focusedController,
              let terminal = controller.terminal else {
            NSSound.beep()
            return
        }
        let script = prepareCommand(command)
        guard !script.isEmpty else { return }
        session.select(terminalTab)
        runtime.invalidate()

        if script.contains("\n") {
            let pasteboard = NSPasteboard.general
            let previous = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(script, forType: .string)
            terminal.paste(self)
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        } else {
            terminal.send(txt: script)
        }
    }

    /// Strips prompt markers and anything that could make the typed text
    /// differ from what the block showed: C0/C1 controls (other than
    /// newlines and tabs) and Unicode bidi formatting characters.
    nonisolated static func prepareCommand(_ command: String) -> String {
        let lines = command
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = Substring(line)
                for prompt in ["$ ", "% ", "> "] where text.hasPrefix(prompt) {
                    text = text.dropFirst(prompt.count)
                    break
                }
                if text == "$" || text == "%" { text = "" }
                return String(text)
            }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return false }
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return false }
            if scalar.value == 0x200E || scalar.value == 0x200F { return false }
            return true
        }.map(Character.init))
    }

    static var selectedPreview: MarkdownPreviewSession? {
        ProjectRuntime.shared.selectedSession?.selectedTab?.web as? MarkdownPreviewSession
    }
}

struct MarkdownPreviewCommands: Commands {
    @State private var runtime = ProjectRuntime.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Markdown Preview…") {
                MarkdownPreviewOpener.openFromPanel()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            // One ⌘R for every web tab: a preview re-reads its file, a
            // browser reloads its page.
            Button("Reload") {
                if let preview = MarkdownPreviewOpener.selectedPreview {
                    preview.reload()
                } else {
                    BrowserOpener.selectedBrowser?.reload()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(selectedPreview == nil && selectedBrowser == nil)

            Button("Open Preview in Editor") {
                MarkdownPreviewOpener.selectedPreview?.openInEditor()
            }
            .disabled(selectedPreview == nil)
        }
    }

    /// Read through the observed runtime so the items enable and disable
    /// as the selected tab changes.
    private var selectedPreview: MarkdownPreviewSession? {
        _ = runtime.revision
        return MarkdownPreviewOpener.selectedPreview
    }

    private var selectedBrowser: BrowserSession? {
        _ = runtime.revision
        return BrowserOpener.selectedBrowser
    }
}
