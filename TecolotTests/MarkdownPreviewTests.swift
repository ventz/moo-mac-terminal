import AppKit
import Darwin
import Foundation
import Testing
@testable import Tecolot

final class MarkdownSchemeHandlerTests {
    private let root: URL = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownSchemeHandlerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: base.appendingPathComponent("README.md").path, contents: Data("# hi".utf8))
        FileManager.default.createFile(atPath: base.appendingPathComponent("docs/shot.png").path, contents: Data([0x89]))
        // A symlink pointing outside the root must not be followed.
        try? FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("escape"),
            withDestinationURL: FileManager.default.temporaryDirectory
        )
        return base.standardizedFileURL.resolvingSymlinksInPath()
    }()

    @Test func resolvesFilesInsideTheRoot() {
        #expect(MarkdownSchemeHandler.resolve("README.md", under: root)?.lastPathComponent == "README.md")
        #expect(MarkdownSchemeHandler.resolve("docs/shot.png", under: root)?.path == root.appendingPathComponent("docs/shot.png").path)
        #expect(MarkdownSchemeHandler.resolve("docs/../README.md", under: root)?.lastPathComponent == "README.md")
    }

    @Test func refusesEscapes() {
        #expect(MarkdownSchemeHandler.resolve("../secret", under: root) == nil)
        #expect(MarkdownSchemeHandler.resolve("docs/../../secret", under: root) == nil)
        #expect(MarkdownSchemeHandler.resolve("/etc/passwd", under: root) == nil || MarkdownSchemeHandler.resolve("/etc/passwd", under: root)?.path.hasPrefix(root.path) == true)
        #expect(MarkdownSchemeHandler.resolve("escape/anything", under: root) == nil)
        #expect(MarkdownSchemeHandler.resolve("", under: root) == nil)
    }

    @Test func documentURLsRoundTrip() async {
        let token = await MarkdownDocumentRegistry.register(root: root)
        let url = MarkdownSchemeHandler.documentURL(token: token, relativePath: "docs/shot.png")
        #expect(url.scheme == MarkdownSchemeHandler.scheme)
        #expect(url.host == MarkdownSchemeHandler.host)
        let file = await MarkdownSchemeHandler.fileURL(for: url)
        #expect(file?.path == root.appendingPathComponent("docs/shot.png").path)

        await MarkdownDocumentRegistry.unregister(token)
        let gone = await MarkdownSchemeHandler.fileURL(for: url)
        #expect(gone == nil)
    }

    @Test func foreignURLsAreNotDocuments() async {
        #expect(await MarkdownSchemeHandler.fileURL(for: URL(string: "https://example.com/x.md")!) == nil)
        #expect(await MarkdownSchemeHandler.fileURL(for: MarkdownSchemeHandler.appURL("markdown-preview.js")) == nil)
    }

    @Test func overlyBroadRootsServeNoSubresources() {
        #expect(!MarkdownSchemeHandler.isReasonableRoot(URL(fileURLWithPath: "/")))
        #expect(!MarkdownSchemeHandler.isReasonableRoot(FileManager.default.homeDirectoryForCurrentUser))
        #expect(!MarkdownSchemeHandler.isReasonableRoot(URL(fileURLWithPath: "/Volumes/Data")))
        #expect(MarkdownSchemeHandler.isReasonableRoot(root))
        #expect(MarkdownSchemeHandler.isReasonableRoot(URL(fileURLWithPath: "/Volumes/Data/repo")))
    }

    @Test func onlyMediaIsServedFromTheDocumentDirectory() {
        for ext in ["png", "svg", "woff2", "mp4", "pdf"] {
            #expect(MarkdownSchemeHandler.subresourceExtensions.contains(ext))
        }
        for ext in ["swift", "env", "pem", "key", "json", "txt", "html", "js"] {
            #expect(!MarkdownSchemeHandler.subresourceExtensions.contains(ext))
        }
    }

    @Test func mimeTypes() {
        #expect(MarkdownSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/x.wasm")) == "application/wasm")
        #expect(MarkdownSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/x.js")).hasPrefix("text/javascript"))
        #expect(MarkdownSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/x.png")) == "image/png")
        #expect(MarkdownSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/x.woff2")) == "font/woff2")
    }
}

final class MarkdownRunCommandTests {
    @Test func promptsAreStripped() {
        #expect(MarkdownPreviewOpener.prepareCommand("$ brew install x") == "brew install x")
        #expect(MarkdownPreviewOpener.prepareCommand("% ls\n$ pwd") == "ls\npwd")
        #expect(MarkdownPreviewOpener.prepareCommand("$\n") == "")
        #expect(MarkdownPreviewOpener.prepareCommand("   ") == "")
    }

    @Test func hiddenCharactersAreRemoved() {
        // A right-to-left override would make the block read differently
        // from what the shell receives.
        #expect(MarkdownPreviewOpener.prepareCommand("echo \u{202E}evil") == "echo evil")
        #expect(MarkdownPreviewOpener.prepareCommand("echo a\u{07}b\u{1b}[2J") == "echo ab[2J")
        #expect(MarkdownPreviewOpener.prepareCommand("a\tb") == "a\tb")
    }
}

/// The whole pipeline in a real WKWebView: scheme handler, bundled
/// renderer with its WebAssembly, the script bridge, and the file watcher.
@MainActor
final class MarkdownPreviewSessionTests {
    private func makeDocument(_ markdown: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPreviewSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("README.md")
        try? markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func rendersAFileAndFollowsEdits() async {
        let file = makeDocument("# Title\n\n```python\ndef f(): pass\n```\n")
        let session = MarkdownPreviewSession(fileURL: file)
        #expect(session.kind == .markdown)
        #expect(session.displayTitle == "README.md")
        #expect(session.currentDirectory == file.deletingLastPathComponent().path)

        // Off screen, but in a window: WebKit only loads in a window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.hostedView
        #expect(session.hasHostedView)

        await waitUntil(15) { session.state == .ready }
        #expect(session.state == .ready, "renderer did not report a render: \(session.state)")
        let firstRender = session.lastRenderedAt

        try? "# Changed\n".write(to: file, atomically: true, encoding: .utf8)
        await waitUntil(5) { session.lastRenderedAt != firstRender }
        #expect(session.lastRenderedAt != firstRender, "edit was not re-rendered")

        session.terminate()
        #expect(!session.hasHostedView)
        window.close()
    }
}

@MainActor
final class MarkdownFileWatcherTests {
    private func makeFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownFileWatcherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("README.md")
        try? "one".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Polls rather than sleeping a fixed time: other suites (the WKWebView
    /// one in particular) share the main thread, so a debounced event can
    /// take well over its nominal delay to be delivered.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func firstReadFiresAndAtomicSavesAreSeen() async {
        let file = makeFile()
        var events: [MarkdownFileWatcher.Event] = []
        let watcher = MarkdownFileWatcher(fileURL: file, debounce: 0.05) { events.append($0) }
        watcher.start()
        defer { watcher.stop() }

        guard case .changed("one")? = events.first else {
            Issue.record("expected the initial content, got \(events)")
            return
        }

        // vim-style save: write a temporary file, rename over the original.
        let temporary = file.deletingLastPathComponent().appendingPathComponent("README.md.tmp")
        try? "two".write(to: temporary, atomically: false, encoding: .utf8)
        #expect(rename(temporary.path, file.path) == 0)
        await waitUntil(5) { events.count > 1 }

        guard case .changed("two")? = events.last else {
            Issue.record("expected the renamed-in content, got \(events)")
            return
        }
    }

    @Test func unchangedContentDoesNotFire() async {
        let file = makeFile()
        var count = 0
        let watcher = MarkdownFileWatcher(fileURL: file, debounce: 0.05) { _ in count += 1 }
        watcher.start()
        defer { watcher.stop() }
        #expect(count == 1)

        // Touch without changing the bytes.
        try? "one".write(to: file, atomically: true, encoding: .utf8)
        await wait(0.4)
        #expect(count == 1)

        watcher.reload(force: true)
        #expect(count == 2)
    }

    @Test func deletionReportsMissing() async {
        let file = makeFile()
        var events: [MarkdownFileWatcher.Event] = []
        let watcher = MarkdownFileWatcher(fileURL: file, debounce: 0.05) { events.append($0) }
        watcher.start()
        defer { watcher.stop() }

        try? FileManager.default.removeItem(at: file)
        await waitUntil(5) { events.count > 1 }
        guard case .missing? = events.last else {
            Issue.record("expected .missing, got \(events)")
            return
        }
    }
}
