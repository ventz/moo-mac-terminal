import AppKit
import Foundation
import Testing
@testable import Moo

/// A stand-in for the preview and browser sessions: enough to be a tab.
@MainActor
final class StubWebContent: WebTabContent {
    let kind: WorkspaceTabKind
    var displayTitle: String
    var currentDirectory: String?
    private(set) var terminateCount = 0
    private(set) var focusCount = 0
    private var view: NSView?

    init(kind: WorkspaceTabKind = .browser, title: String = "Stub", directory: String? = nil) {
        self.kind = kind
        displayTitle = title
        currentDirectory = directory
    }

    var hostedView: NSView {
        if let view { return view }
        let created = NSView(frame: .zero)
        view = created
        return created
    }

    var hasHostedView: Bool { view != nil }

    func focus() { focusCount += 1 }

    func terminate() {
        terminateCount += 1
        view = nil
    }
}

/// Tabs holding web content beside terminal tabs. startsProcesses: false, so
/// the terminal tabs here spawn nothing.
@MainActor
final class WebTabContentTests {
    private func makeSession() -> WorkspaceSession {
        WorkspaceSession(projectID: UUID(), startsProcesses: false)
    }

    @Test func webTabReportsItsKindAndTitle() {
        let session = makeSession()
        let content = StubWebContent(kind: .markdown, title: "README.md", directory: "/tmp/repo")
        let tab = session.addTab(web: content)

        #expect(tab.kind == .markdown)
        #expect(!tab.isTerminal)
        #expect(tab.panes == nil)
        #expect(tab.web === content)
        #expect(tab.displayTitle == "README.md")
        #expect(tab.currentDirectory == "/tmp/repo")
        #expect(tab.controllers.isEmpty)
        #expect(session.selectedTab?.id == tab.id)
    }

    @Test func blankWebTitleFallsBackToTheInitialOne() {
        let content = StubWebContent(title: "Loading…")
        let tab = WorkspaceTab(web: content)
        content.displayTitle = "   "
        #expect(tab.displayTitle == "Loading…")
    }

    @Test func terminalTabsAreUnchanged() {
        let session = makeSession()
        let tab = session.ensureTab()
        #expect(tab.kind == .terminal)
        #expect(tab.isTerminal)
        #expect(tab.panes != nil)
        #expect(tab.web == nil)
        #expect(tab.controllers.count == 1)
    }

    /// Status, quit confirmation and the close prompt all read `controllers`;
    /// a web tab must be invisible to every one of them.
    @Test func sessionControllersSkipWebTabs() {
        let session = makeSession()
        let terminal = session.ensureTab()
        session.addTab(web: StubWebContent())
        session.addTab(web: StubWebContent())

        #expect(session.tabs.count == 3)
        #expect(session.controllers.count == 1)
        #expect(session.controllers.first === terminal.controllers.first)
        #expect(session.tab(containing: terminal.controllers[0])?.id == terminal.id)
    }

    @Test func newTabsLandBesideTheSelectedOne() {
        let session = makeSession()
        let first = session.ensureTab()
        let last = session.addTab()
        session.select(first)
        let preview = session.addTab(web: StubWebContent())

        #expect(session.tabs.map(\.id) == [first.id, preview.id, last.id])
        #expect(session.selectedTab?.id == preview.id)
    }

    @Test func closingAWebTabTerminatesItsContent() {
        let session = makeSession()
        session.ensureTab()
        let content = StubWebContent()
        let tab = session.addTab(web: content)
        _ = content.hostedView

        session.close(tab)
        #expect(content.terminateCount == 1)
        #expect(!content.hasHostedView)
        #expect(session.tabs.count == 1)
    }

    /// The terminal host keeps showing the last terminal while a web tab is
    /// in front, so switching back is instant and nothing is restarted.
    @Test func mostRecentTerminalTabFollowsSelection() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()
        let preview = session.addTab(web: StubWebContent())

        #expect(session.selectedTab?.id == preview.id)
        #expect(session.mostRecentTerminalTab?.id == second.id)

        session.select(first)
        session.select(preview)
        #expect(session.mostRecentTerminalTab?.id == first.id)
    }

    @Test func closingTheRememberedTerminalFallsBackToAnother() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()
        let preview = session.addTab(web: StubWebContent())

        session.close(second)
        #expect(session.selectedTab?.id == preview.id)
        #expect(session.mostRecentTerminalTab?.id == first.id)
    }

    @Test func closingEveryTerminalLeavesNoTerminalToShow() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()
        let preview = session.addTab(web: StubWebContent())

        session.close(first)
        session.close(second)
        #expect(session.selectedTab?.id == preview.id)
        #expect(session.mostRecentTerminalTab == nil)
        #expect(session.controllers.isEmpty)
    }

    @Test func terminateAllTerminatesWebContent() {
        let session = makeSession()
        session.ensureTab()
        let content = StubWebContent()
        session.addTab(web: content)
        session.terminateAll()
        #expect(content.terminateCount == 1)
        #expect(session.isEmpty)
    }

    @Test func webOnlyWorkspaceHasNoTerminalToShow() {
        let session = makeSession()
        session.addTab(web: StubWebContent())
        #expect(session.mostRecentTerminalTab == nil)
        #expect(session.controllers.isEmpty)
        #expect(!session.isEmpty)
    }

    /// Closing the last tab of any kind leaves a terminal, never a web tab:
    /// a workspace always has a shell to come back to.
    @Test func closingTheLastWebTabLeavesATerminal() {
        let session = makeSession()
        let tab = session.addTab(web: StubWebContent())
        session.close(tab)
        #expect(session.tabs.count == 1)
        #expect(session.tabs[0].isTerminal)
    }

    @Test func cyclingCrossesTabKinds() {
        let session = makeSession()
        let terminal = session.ensureTab()
        let preview = session.addTab(web: StubWebContent())

        session.selectNextTab()
        #expect(session.selectedTab?.id == terminal.id)
        session.selectPreviousTab()
        #expect(session.selectedTab?.id == preview.id)
    }

    @Test func runtimeDirectoriesIncludeWebTabs() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let projectID = UUID()
        runtime.select(projectID: projectID)
        let session = runtime.session(for: projectID)
        session.addTab(web: StubWebContent(directory: "/tmp/docs"))

        #expect(runtime.tabDirectories(for: projectID).contains("/tmp/docs"))
        #expect(runtime.currentDirectory(for: projectID) == "/tmp/docs")
    }

    @Test func hostViewSwapsChildrenWithoutRecreatingThem() {
        let host = WebTabHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let first = StubWebContent()
        let second = StubWebContent()

        host.show(first)
        let firstView = first.hostedView
        #expect(host.subviews.first === firstView)

        host.show(first)
        #expect(host.subviews.count == 1)

        host.show(second)
        #expect(host.subviews.first === second.hostedView)
        #expect(first.hasHostedView, "detaching must not release the page")

        host.show(nil)
        #expect(host.subviews.isEmpty)
        #expect(host.content == nil)
    }
}

final class LinkRouterTests {
    private let directory: String = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkRouterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["README.md", "notes.markdown", "main.swift"] {
            FileManager.default.createFile(atPath: base.appendingPathComponent(name).path, contents: Data())
        }
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("docs.md"), withIntermediateDirectories: true
        )
        return base.path
    }()

    @Test func webAddressesGoToTheBrowser() {
        #expect(LinkRouter.classify("https://example.com/a?b=1", workingDirectory: nil)
            == .browser(URL(string: "https://example.com/a?b=1")!))
        #expect(LinkRouter.classify("http://localhost:3000", workingDirectory: nil)
            == .browser(URL(string: "http://localhost:3000")!))
    }

    @Test func otherSchemesStayExternal() {
        #expect(LinkRouter.classify("mailto:a@b.c", workingDirectory: nil) == .external)
        #expect(LinkRouter.classify("ssh://host", workingDirectory: nil) == .external)
    }

    @Test func markdownFileURLsPreview() {
        let url = URL(fileURLWithPath: directory + "/README.md")
        #expect(LinkRouter.classify(url.absoluteString, workingDirectory: nil) == .markdownPreview(url))
        let swift = URL(fileURLWithPath: directory + "/main.swift")
        #expect(LinkRouter.classify(swift.absoluteString, workingDirectory: nil) == .external)
    }

    @Test func relativePathsResolveAgainstTheTerminalDirectory() {
        let expected = URL(fileURLWithPath: directory + "/README.md")
        #expect(LinkRouter.classify("README.md", workingDirectory: directory) == .markdownPreview(expected))
        #expect(LinkRouter.classify("./README.md", workingDirectory: directory) == .markdownPreview(expected))
        #expect(LinkRouter.classify("README.md:12:3", workingDirectory: directory) == .markdownPreview(expected))
        #expect(LinkRouter.classify("README.md", workingDirectory: nil) == .external)
        #expect(LinkRouter.classify("missing.md", workingDirectory: directory) == .external)
    }

    @Test func absoluteMarkdownPathsPreview() {
        let expected = URL(fileURLWithPath: directory + "/notes.markdown")
        #expect(LinkRouter.classify(directory + "/notes.markdown", workingDirectory: nil)
            == .markdownPreview(expected))
    }

    @Test func executablesAreNeverOpened() {
        let script = directory + "/run.sh"
        FileManager.default.createFile(atPath: script, contents: Data())
        let binary = directory + "/tool"
        FileManager.default.createFile(atPath: binary, contents: Data(), attributes: [.posixPermissions: 0o755])
        let plain = directory + "/main.swift"

        #expect(LinkRouter.isExecutable(URL(fileURLWithPath: script)))
        #expect(LinkRouter.isExecutable(URL(fileURLWithPath: binary)))
        #expect(LinkRouter.isExecutable(URL(fileURLWithPath: directory + "/Thing.app")))
        #expect(!LinkRouter.isExecutable(URL(fileURLWithPath: plain)))
        #expect(!LinkRouter.isExecutable(URL(fileURLWithPath: directory + "/README.md")))
    }

    @Test func bareWordUnderAClickIsFoundInItsRow() {
        // `ls` output: tabs leave unwritten cells, which read as NUL.
        func cells(_ text: String) -> [String] { text.map { String($0) } }
        var row: [String] = cells("CLAUDE.md")
        row += ["\0", "\0"]
        row += cells("README.md")
        row += [" "]
        row += cells("(notes.md),")
        #expect(LinkRouter.word(inCells: row, at: 0) == "CLAUDE.md")
        #expect(LinkRouter.word(inCells: row, at: 13) == "README.md")
        #expect(LinkRouter.word(inCells: row, at: 23) == "notes.md")
        #expect(LinkRouter.word(inCells: row, at: 9) == nil)
        #expect(LinkRouter.word(inCells: row, at: 99) == nil)
        #expect(LinkRouter.word(inCells: Array("README.md:12:3").map(String.init), at: 2) == "README.md:12:3")
        #expect(LinkRouter.word(inCells: Array("a ...").map(String.init), at: 3) == nil)
        // The underlined span leaves out the brackets and trailing comma.
        #expect(LinkRouter.wordSpan(inCells: row, at: 23)?.columns == 22..<30)
        #expect(LinkRouter.wordSpan(inCells: row, at: 0)?.columns == 0..<9)
    }

    @Test func copiedRowsSplitBackIntoCells() {
        // The snapshot copy turns unwritten cells into spaces.
        let ls = LinkRouter.cells(fromRowText: "a.md    README.md", cellWidths: Array(repeating: 1, count: 17))
        #expect(LinkRouter.word(inCells: ls, at: 10) == "README.md")
        // A wide character's trailing half is an empty cell inside the word.
        let wide = LinkRouter.cells(fromRowText: "日本.md x", cellWidths: [2, 0, 2, 0, 1, 1, 1, 1, 1])
        #expect(wide.count == 9)
        #expect(LinkRouter.word(inCells: wide, at: 1) == "日本.md")
        #expect(LinkRouter.word(inCells: wide, at: 8) == "x")
    }

    @Test func onlyWebAndMailOpenWithoutAsking() {
        func action(_ link: String, handled: Bool = true) -> LinkRouter.ExternalAction {
            LinkRouter.externalAction(for: link, workingDirectory: directory, hasHandler: { _ in handled })
        }
        #expect(action("https://example.com") == .openURL(URL(string: "https://example.com")!))
        #expect(action("HTTPS://example.com") == .openURL(URL(string: "HTTPS://example.com")!))
        #expect(action("mailto:a@b.c") == .openURL(URL(string: "mailto:a@b.c")!))
        #expect(action("smb://host/share") == .confirm(URL(string: "smb://host/share")!))
        #expect(action("x-man-page://ls") == .confirm(URL(string: "x-man-page://ls")!))
        #expect(action("javascript:alert(1)") == .ignore)
        #expect(action("data:text/html,hi") == .ignore)
        #expect(action("missing.txt:12") == .ignore)
        #expect(action("file:///no/such/file") == .ignore)
        // A word that only looks like a scheme, with no app for it.
        #expect(action("Makefile:12", handled: false) == .ignore)
    }

    @Test func filesAndBundlesGoThroughTheExecutableCheck() {
        let bundle = directory + "/Thing.app"
        try? FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        #expect(LinkRouter.externalAction(for: bundle, workingDirectory: nil)
            == .openFile(URL(fileURLWithPath: bundle)))
        #expect(LinkRouter.externalAction(for: "Thing.app", workingDirectory: directory)
            == .openFile(URL(fileURLWithPath: bundle)))
        #expect(LinkRouter.externalAction(for: "file://" + bundle, workingDirectory: nil)
            == .openFile(URL(string: "file://" + bundle)!))
        #expect(LinkRouter.externalAction(for: "main.swift:3", workingDirectory: directory)
            == .openFile(URL(fileURLWithPath: directory + "/main.swift")))
    }

    @Test func remoteShellDirectoriesAreNotLocal() {
        let names: Set<String> = ["localhost", "moo-mac.local", "moo-mac"]
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "kitty-shell-cwd://moo-mac/Users/me", localHostNames: names) == "/Users/me")
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "file://Moo-Mac.local/tmp", localHostNames: names) == "/tmp")
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "file:///tmp", localHostNames: names) == "/tmp")
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "file://moo-mac.local./tmp", localHostNames: names) == "/tmp")
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "file://prod-db-1/var/lib", localHostNames: names) == nil)
        #expect(TerminalSessionController.localDirectory(
            fromOSC7: "file://moo-mac.example.com/tmp", localHostNames: names) == nil)
    }

    @Test func symlinksAreJudgedByTheirTarget() throws {
        let target = directory + "/run"
        FileManager.default.createFile(atPath: target, contents: Data(), attributes: [.posixPermissions: 0o755])
        let link = directory + "/README"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(!LinkRouter.isExecutable(URL(fileURLWithPath: link)))
        #expect(LinkRouter.isExecutable(URL(fileURLWithPath: link).resolvingSymlinksInPath()))
    }

    @Test func nonMarkdownAndDirectoriesStayExternal() {
        #expect(LinkRouter.classify("main.swift", workingDirectory: directory) == .external)
        #expect(LinkRouter.classify("docs.md", workingDirectory: directory) == .external)
    }
}
