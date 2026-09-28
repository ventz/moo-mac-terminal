import AppKit
import Foundation
import Testing
@testable import Moo

/// The Finder services: which directories a selection turns into, and where
/// the new tab's shell starts. No shells are spawned.
@MainActor
final class FinderServicesTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderServicesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("folder/file.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: String {
        (root.appendingPathComponent("folder").path as NSString).standardizingPath
    }

    @Test func aSelectedFolderOpensInItself() {
        let result = FinderServiceDirectories.resolve(
            fileURLs: [root.appendingPathComponent("folder")],
            text: nil
        )
        #expect(result == [folder])
    }

    @Test func aSelectedFileOpensInTheFolderHoldingIt() {
        let result = FinderServiceDirectories.resolve(
            fileURLs: [root.appendingPathComponent("folder/file.txt")],
            text: nil
        )
        #expect(result == [folder])
    }

    /// A folder and a file inside it are one place, not two tabs.
    @Test func repeatsCollapseInSelectionOrder() {
        let result = FinderServiceDirectories.resolve(
            fileURLs: [
                root.appendingPathComponent("folder/file.txt"),
                root.appendingPathComponent("folder"),
                root,
            ],
            text: nil
        )
        #expect(result == [folder, (root.path as NSString).standardizingPath])
    }

    @Test func missingPathsAreDropped() {
        let result = FinderServiceDirectories.resolve(
            fileURLs: [root.appendingPathComponent("nope")],
            text: nil
        )
        #expect(result.isEmpty)
    }

    /// A path selected as text in another app.
    @Test func selectedTextIsReadAsAPath() {
        let result = FinderServiceDirectories.resolve(
            fileURLs: [],
            text: "  \(root.path)/folder/file.txt\n"
        )
        #expect(result == [folder])
    }

    /// Prose, relative names and several lines are not requests to open.
    @Test func textThatIsNotOneAbsolutePathIsIgnored() {
        for text in ["folder", "see \(folder)", "\(folder)\n\(folder)", ""] {
            #expect(FinderServiceDirectories.resolve(fileURLs: [], text: text).isEmpty)
        }
    }

    @Test func aLargeSelectionIsCapped() throws {
        var urls: [URL] = []
        for index in 0..<(FinderServiceDirectories.maximumCount + 4) {
            let url = root.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
        }
        let result = FinderServiceDirectories.resolve(fileURLs: urls, text: nil)
        #expect(result.count == FinderServiceDirectories.maximumCount)
    }

    /// The service's folder wins over the directory the tab would otherwise
    /// inherit from the terminal beside it.
    @Test func aTabOpenedOnAFolderStartsThere() {
        let session = WorkspaceSession(projectID: UUID(), startsProcesses: false)
        let first = session.ensureTab()
        first.panes?.focusedController?
            .updateCurrentDirectory("kitty-shell-cwd://localhost/Users/ventz/git")

        let added = session.addTab(directory: folder)
        #expect(added.panes?.focusedController?.pendingLaunchDirectory == folder)
        #expect(session.selectedTab?.id == added.id)
    }

    /// Even with directory inheritance off, which only governs ⌘T.
    @Test func aTabOpenedOnAFolderIgnoresTheInheritanceSetting() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "newTabsUseCurrentDirectory")
        defaults.set(false, forKey: "newTabsUseCurrentProfile")
        defer {
            defaults.removeObject(forKey: "newTabsUseCurrentDirectory")
            defaults.removeObject(forKey: "newTabsUseCurrentProfile")
        }
        let session = WorkspaceSession(projectID: UUID(), startsProcesses: false)
        session.ensureTab()

        let added = session.addTab(directory: folder)
        #expect(added.panes?.focusedController?.pendingLaunchDirectory == folder)
    }

    /// Info.plist names each handler by selector; a renamed method would drop
    /// its menu entry without any error.
    @Test func everyDeclaredServiceHasAHandler() throws {
        let services = try #require(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let messages = services.compactMap { $0["NSMessage"] as? String }
        #expect(messages.sorted() == ["openTabHere", "openWindowHere", "openWorkspaceHere"])
        for message in messages {
            let selector = NSSelectorFromString("\(message):userData:error:")
            #expect(FinderServiceProvider.shared.responds(to: selector), "\(message)")
        }
    }
}
