import AppKit
import Darwin
import Foundation
import Testing
@testable import Moo

@MainActor
final class WorkspaceRestoreTests {
    private let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRestoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pane(_ directory: String?) -> SavedPane {
        .terminal(directory: directory, profileID: nil, themeOverride: nil)
    }

    /// Two tabs; the second is a vertical split whose right side is split
    /// again, with one directory that exists, one that is gone, and none.
    private func document(projectID: UUID) -> WorkspaceRestoreDocument {
        let split = SavedPane.split(
            .vertical,
            pane(directory.path),
            .split(.horizontal, pane("/no/such/dir"), pane(nil))
        )
        return WorkspaceRestoreDocument(
            windows: [SavedWindow(projectID: projectID, showsSidebar: true)],
            workspaces: [SavedWorkspace(
                projectID: projectID,
                selectedTabIndex: 1,
                tabs: [SavedTab(root: pane(directory.path)), SavedTab(root: split)]
            )]
        )
    }

    @Test func documentsRoundTrip() throws {
        let saved = document(projectID: UUID())
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(WorkspaceRestoreDocument.self, from: data) == saved)
    }

    @Test func aSavedWorkspaceIsRebuiltOnFirstVisit() throws {
        let runtime = ProjectRuntime(startsProcesses: false)
        let projectID = UUID()
        runtime.prepareRestore(document(projectID: projectID))
        #expect(!runtime.isRunning(projectID))

        let session = runtime.session(for: projectID)
        #expect(session.tabs.count == 2)
        #expect(session.selectedTab?.id == session.tabs[1].id)

        let panes = try #require(session.tabs[1].panes)
        #expect(panes.paneCount == 3)
        #expect(panes.controllers[0].pendingLaunchDirectory == directory.path)
        #expect(panes.controllers[1].pendingLaunchDirectory == nil)
        #expect(panes.controllers[2].pendingLaunchDirectory == nil)
        guard case .split(.vertical, _, let right) = panes.root.content,
              case .split(.horizontal, _, _) = right.content else {
            Issue.record("the split layout should survive")
            return
        }
        // A second visit does not rebuild again.
        #expect(runtime.session(for: projectID) === session)
    }

    @Test func snapshotsKeepTerminalTabsAndUnvisitedWorkspaces() throws {
        let runtime = ProjectRuntime(startsProcesses: false)
        let visited = UUID()
        let unvisited = UUID()
        runtime.prepareRestore(document(projectID: unvisited))

        let session = runtime.session(for: visited)
        let tab = session.ensureTab()
        let panes = try #require(tab.panes)
        panes.split(panes.controllers[0], orientation: .horizontal)
        session.addTab(web: StubWebContent())

        let snapshot = runtime.restoreSnapshot()
        // No window is open, so the one still waiting to come back is kept.
        #expect(snapshot.windows == [SavedWindow(projectID: unvisited, showsSidebar: true)])
        let saved = try #require(snapshot.workspaces.first { $0.projectID == visited })
        #expect(saved.tabs.count == 1)
        #expect(saved.selectedTabIndex == 0)
        guard case .split(.horizontal, _, _) = saved.tabs[0].root else {
            Issue.record("the split should be saved")
            return
        }
        #expect(snapshot.workspaces.contains { $0.projectID == unvisited })
        // A deleted project's workspace is dropped from the file.
        #expect(!runtime.restoreSnapshot(existingProjectIDs: [visited]).workspaces
            .contains { $0.projectID == unvisited })
    }

    @Test func windowsSkipDeletedWorkspaces() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let kept = UUID()
        runtime.prepareRestore(WorkspaceRestoreDocument(
            windows: [
                SavedWindow(projectID: UUID(), showsSidebar: false),
                SavedWindow(projectID: nil, showsSidebar: false),
                SavedWindow(projectID: kept, showsSidebar: true)
            ],
            workspaces: []
        ))
        // The window with no workspace is dropped; the deleted one does not
        // count toward windows to open.
        #expect(runtime.pendingRestoredWindowCount == 2)
        #expect(runtime.restorableWindowCount(existing: [kept]) == 1)
        #expect(runtime.takeRestoredWindow(existing: [kept]) == SavedWindow(projectID: kept, showsSidebar: true))
        #expect(runtime.takeRestoredWindow(existing: [kept]) == nil)
    }

    @Test func onlyTheUsersOwnLocalDirectoriesAreRestored() {
        #expect(RestoredDirectory.validated(directory.path) != nil)
        #expect(RestoredDirectory.validated("relative/path") == nil)
        #expect(RestoredDirectory.validated("/Volumes/Share/project") == nil)
        #expect(RestoredDirectory.validated("/no/such/dir") == nil)
        #expect(RestoredDirectory.validated("/usr") == nil)
        #expect(RestoredDirectory.validated(directory.path, userID: getuid() + 1) == nil)

        let file = directory.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(RestoredDirectory.validated(file.path) == nil)

        let link = directory.appendingPathComponent("link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(RestoredDirectory.validated(link.path) == nil)
        #expect(RestoredDirectory.validated("/home/someone/project") == nil)
    }

    @Test func theShellsRealDirectoryComesFromTheKernel() {
        #expect(TerminalProcessInspector.workingDirectory(of: getpid()) == FileManager.default.currentDirectoryPath)
        #expect(TerminalProcessInspector.workingDirectory(of: -1) == nil)
    }

    @Test func aFileCannotAskForTooMuch() {
        let runtime = ProjectRuntime(startsProcesses: false)
        runtime.prepareRestore(WorkspaceRestoreDocument(
            windows: (0..<200).map { _ in SavedWindow(projectID: UUID(), showsSidebar: true) },
            workspaces: []
        ))
        #expect(runtime.pendingRestoredWindowCount == WorkspaceRestoreDocument.maximumWindows)

        let projectID = UUID()
        runtime.prepareRestore(WorkspaceRestoreDocument(windows: [], workspaces: [SavedWorkspace(
            projectID: projectID,
            selectedTabIndex: 500,
            tabs: Array(repeating: SavedTab(root: pane(nil)), count: 100)
        )]))
        let session = runtime.session(for: projectID)
        #expect(session.tabs.count == SavedWorkspace.maximumTabs)
        #expect(session.selectedTab?.id == session.tabs.last?.id)

        let deep = Data((String(repeating: "[", count: 500) + String(repeating: "]", count: 500)).utf8)
        #expect(WorkspaceRestoreStore.nestingDepth(of: deep) == 500)
        #expect(WorkspaceRestoreStore.nestingDepth(of: Data(#"{"a":"[[[[\"{"}"#.utf8)) == 1)
    }

    @Test func aDamagedTreeIsCutBack() {
        var deep = pane(nil)
        for _ in 0..<50 {
            deep = .split(.vertical, deep, pane(nil))
        }
        #expect(TerminalPaneWorkspace(startsProcesses: false, restoring: deep).paneCount
            <= SavedPane.maximumDepth + 1)

        func balanced(_ depth: Int) -> SavedPane {
            depth == 0 ? pane(nil) : .split(.horizontal, balanced(depth - 1), balanced(depth - 1))
        }
        #expect(TerminalPaneWorkspace(startsProcesses: false, restoring: balanced(10)).paneCount
            <= SavedPane.maximumPanes + SavedPane.maximumDepth)
    }

    /// Closing the last window ends the shells but not the layout: it is
    /// saved, and held so the next autosave and the next window keep it.
    @Test(.enabled(if: WorkspaceRestoreDefaults.isEnabled))
    func closingTheLastWindowKeepsItsLayout() throws {
        let runtime = ProjectRuntime(startsProcesses: false)
        let store = WorkspaceRestoreStore(directory: directory)
        runtime.beginRestore(from: store, restoring: false)
        let projectID = UUID()
        runtime.existingProjectIDs = { [projectID] }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let scope = WindowScope()
        scope.window = window
        runtime.register(scope)
        runtime.select(projectID: projectID, in: scope)
        let panes = try #require(runtime.session(for: projectID).ensureTab().panes)
        panes.split(panes.controllers[0], orientation: .vertical)

        runtime.windowWillClose(window)

        #expect(runtime.existingSession(for: projectID) == nil)
        let saved = try #require(store.load())
        #expect(saved.windows.map(\.projectID) == [projectID])
        let workspace = try #require(saved.workspaces.first { $0.projectID == projectID })
        guard case .split(.vertical, _, _) = workspace.tabs[0].root else {
            Issue.record("the split should be saved")
            return
        }
        #expect(runtime.restoreSnapshot(existingProjectIDs: [projectID]) == saved)
    }

    @Test func theStoreIgnoresDamageAndWritesPrivately() throws {
        let store = WorkspaceRestoreStore(directory: directory)
        #expect(store.load() == nil)

        let saved = document(projectID: UUID())
        store.save(saved)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(WorkspaceRestoreStore(directory: directory).load() == saved)

        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(WorkspaceRestoreStore(directory: directory).load() == nil)

        var future = saved
        future.version = WorkspaceRestoreDocument.currentVersion + 1
        try JSONEncoder().encode(future).write(to: store.fileURL)
        #expect(WorkspaceRestoreStore(directory: directory).load() == nil)

        store.remove()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
