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
    /// most recent terminal and brings it to the front. Prompt markers are
    /// stripped so a block copied from documentation runs as written.
    static func run(command: String, from preview: MarkdownPreviewSession) {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession,
              let terminalTab = session.mostRecentTerminalTab,
              let controller = terminalTab.panes?.focusedController,
              let terminal = controller.terminal else {
            NSSound.beep()
            return
        }
        let lines = command
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = Substring(line)
                if text.hasPrefix("$ ") { text = text.dropFirst(2) }
                else if text == "$" { text = "" }
                return String(text)
            }
        let script = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        session.select(terminalTab)
        runtime.invalidate()
        terminal.send(txt: script + "\n")
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
            Button("Reload Preview") {
                MarkdownPreviewOpener.selectedPreview?.reload()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(selectedPreview == nil)

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
}
