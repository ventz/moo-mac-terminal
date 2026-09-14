import AppKit
import Foundation
import Testing
@testable import Moo

/// startsProcesses: false throughout — these cover the tab/workspace model,
/// not the terminal, so no shells are spawned.
@MainActor
final class WorkspaceSessionTests {
    private func makeSession() -> WorkspaceSession {
        WorkspaceSession(projectID: UUID(), startsProcesses: false)
    }

    @Test func startsEmptyAndFirstVisitCreatesOneTab() {
        let session = makeSession()
        #expect(session.isEmpty)
        #expect(session.selectedTab == nil)

        let tab = session.ensureTab()
        #expect(session.tabs.count == 1)
        #expect(session.selectedTab?.id == tab.id)
    }

    /// Visiting again must not keep stacking tabs.
    @Test func ensureTabIsIdempotent() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.ensureTab()
        #expect(first.id == second.id)
        #expect(session.tabs.count == 1)
    }

    @Test func addTabSelectsTheNewTab() {
        let session = makeSession()
        session.ensureTab()
        let added = session.addTab()
        #expect(session.tabs.count == 2)
        #expect(session.selectedTab?.id == added.id)
    }

    /// Closing the last tab leaves a fresh one, so a workspace you switch to
    /// always has a terminal to show.
    @Test func closingTheLastTabLeavesAFreshOne() {
        let session = makeSession()
        let only = session.ensureTab()
        session.close(only)

        #expect(session.tabs.count == 1)
        #expect(session.tabs[0].id != only.id)
        #expect(session.selectedTab != nil)
    }

    @Test func closingSelectedTabSelectsANeighbour() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()
        let third = session.addTab()

        session.select(second)
        session.close(second)

        #expect(session.tabs.map(\.id) == [first.id, third.id])
        #expect(session.selectedTab?.id == third.id)
    }

    /// Closing a tab that is not selected must not move the selection.
    @Test func closingAnotherTabKeepsSelection() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()
        session.select(second)

        session.close(first)
        #expect(session.selectedTab?.id == second.id)
    }

    @Test func cyclingWrapsInBothDirections() {
        let session = makeSession()
        let a = session.ensureTab()
        let b = session.addTab()
        let c = session.addTab()

        session.select(a)
        session.selectNextTab()
        #expect(session.selectedTab?.id == b.id)
        session.selectNextTab()
        #expect(session.selectedTab?.id == c.id)
        session.selectNextTab()
        #expect(session.selectedTab?.id == a.id)   // wraps forward
        session.selectPreviousTab()
        #expect(session.selectedTab?.id == c.id)   // wraps backward
    }

    @Test func cyclingASingleTabIsANoOp() {
        let session = makeSession()
        let only = session.ensureTab()
        session.selectNextTab()
        #expect(session.selectedTab?.id == only.id)
    }

    @Test func selectByIndexIgnoresOutOfRange() {
        let session = makeSession()
        let first = session.ensureTab()
        session.addTab()
        session.select(index: 0)
        #expect(session.selectedTab?.id == first.id)

        session.select(index: 99)
        #expect(session.selectedTab?.id == first.id)
    }

    /// Selecting a tab from a different session must be rejected rather than
    /// leaving the session pointing at a tab it does not own.
    @Test func selectingAForeignTabIsIgnored() {
        let session = makeSession()
        let own = session.ensureTab()
        let other = makeSession()
        let foreign = other.ensureTab()

        session.select(foreign)
        #expect(session.selectedTab?.id == own.id)
    }
}

@MainActor
final class ProjectRuntimeSessionTests {
    @Test func sessionsAreCreatedOnceAndKept() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        let first = runtime.session(for: id)
        let second = runtime.session(for: id)
        #expect(first === second)
    }

    /// Asking for a session must not start a shell; only a tab does.
    @Test func creatingASessionDoesNotCreateATab() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        #expect(runtime.session(for: id).isEmpty)
        #expect(!runtime.isRunning(id))
    }

    @Test func selectingAWorkspaceGivesItATab() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        runtime.select(projectID: id)

        #expect(runtime.selectedProjectID == id)
        #expect(runtime.isRunning(id))
        #expect(runtime.session(for: id).tabs.count == 1)
    }

    /// The heart of the feature: switching away and back must not disturb the
    /// workspace you left — same session object, same tabs.
    @Test func switchingBackAndForthPreservesEachWorkspace() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let one = UUID()
        let two = UUID()

        runtime.select(projectID: one)
        let oneSession = runtime.session(for: one)
        oneSession.addTab()                      // workspace one now has 2 tabs
        let oneTabIDs = oneSession.tabs.map(\.id)

        runtime.select(projectID: two)
        #expect(runtime.session(for: two).tabs.count == 1)

        runtime.select(projectID: one)
        #expect(runtime.session(for: one) === oneSession)
        #expect(runtime.session(for: one).tabs.map(\.id) == oneTabIDs)
        #expect(runtime.session(for: two).tabs.count == 1)
    }

    @Test func reselectingTheSameWorkspaceChangesNothing() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        runtime.select(projectID: id)
        let tabIDs = runtime.session(for: id).tabs.map(\.id)
        runtime.select(projectID: id)
        #expect(runtime.session(for: id).tabs.map(\.id) == tabIDs)
    }

    @Test func discardingASessionClearsItAndTheSelection() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        runtime.select(projectID: id)
        runtime.discardSession(for: id)

        #expect(runtime.selectedProjectID == nil)
        #expect(!runtime.isRunning(id))
    }

    /// A workspace that is off screen still counts for quit confirmation.
    @Test func allControllersSpansEveryWorkspace() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let one = UUID()
        let two = UUID()
        runtime.select(projectID: one)
        runtime.select(projectID: two)

        // One controller per tab, one tab per workspace.
        #expect(runtime.allControllers.count == 2)
    }

    @Test func statusIsColdUntilVisited() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let id = UUID()
        #expect(runtime.status(for: id).status == .cold)
        runtime.select(projectID: id)
        #expect(runtime.status(for: id).status != .cold)
    }

    // MARK: Per-window selection
    //
    // Selection used to be one global value, so every window rendered the same
    // workspace and the second window pulled the live terminal view out of the
    // first, leaving it an empty frame. These pin the behavior that fixed it.

    @Test func eachWindowKeepsItsOwnSelection() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)
        let one = UUID()
        let two = UUID()

        runtime.select(projectID: one, in: first)
        runtime.select(projectID: two, in: second)

        #expect(first.selectedProjectID == one)
        #expect(second.selectedProjectID == two)
    }

    /// A workspace's terminals are AppKit views that live in one window only,
    /// so a second window must not take one that is already on screen.
    @Test func selectingAWorkspaceAnotherWindowShowsDoesNotMoveIt() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)
        let shared = UUID()
        let other = UUID()

        runtime.select(projectID: shared, in: first)
        runtime.select(projectID: other, in: second)
        runtime.select(projectID: shared, in: second)

        #expect(first.selectedProjectID == shared)
        #expect(second.selectedProjectID == other)
    }

    @Test func reselectingInTheSameWindowStillWorks() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let scope = WindowScope()
        runtime.register(scope)
        let id = UUID()

        runtime.select(projectID: id, in: scope)
        runtime.select(projectID: id, in: scope)

        #expect(scope.selectedProjectID == id)
        #expect(runtime.session(for: id).tabs.count == 1)
    }

    /// What makes cmd+N a new window rather than a clone.
    @Test func aNewWindowTakesTheFirstUnshownWorkspace() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        runtime.register(first)
        let one = Project(name: "one")
        let two = Project(name: "two")

        runtime.select(projectID: one.id, in: first)

        #expect(runtime.firstUnshownProject(among: [one, two])?.id == two.id)
        #expect(runtime.firstUnshownProject(among: [one])  == nil)
    }

    @Test func visibilitySpansEveryWindow() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let scope = WindowScope()
        runtime.register(scope)
        let id = UUID()
        #expect(!runtime.isVisible(id))
        runtime.select(projectID: id, in: scope)
        #expect(runtime.isVisible(id))
    }

    @Test func discardingClearsTheSelectionInEveryWindow() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)
        let id = UUID()

        runtime.select(projectID: id, in: first)
        runtime.discardSession(for: id)

        #expect(first.selectedProjectID == nil)
        #expect(second.selectedProjectID == nil)
        #expect(!runtime.isRunning(id))
    }

    @Test func unregisteringAWindowReleasesItsWorkspace() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)
        let id = UUID()

        runtime.select(projectID: id, in: first)
        runtime.unregister(first)

        // With the first window gone the workspace is free to be adopted.
        runtime.select(projectID: id, in: second)
        #expect(second.selectedProjectID == id)
    }
}

@MainActor
final class WorkspaceTabClosePolicyTests {
    private func makeSession() -> WorkspaceSession {
        WorkspaceSession(projectID: UUID(), startsProcesses: false)
    }

    /// The default: a workspace keeps a usable terminal, so closing its last
    /// tab leaves a fresh one behind.
    @Test func closingLastTabReplacesItByDefault() {
        let session = makeSession()
        let only = session.ensureTab()
        session.close(only)

        #expect(session.tabs.count == 1)
        #expect(session.tabs[0].id != only.id)
    }

    /// When the workspace itself is being retired, the last tab must actually
    /// go — replacing it would resurrect the thing being closed.
    @Test func closingLastTabCanLeaveTheSessionEmpty() {
        let session = makeSession()
        let only = session.ensureTab()
        session.close(only, replaceWhenEmpty: false)

        #expect(session.isEmpty)
        #expect(session.selectedTab == nil)
    }

    /// The flag only matters for the final tab; closing one of several behaves
    /// the same either way.
    @Test func replaceFlagIsIrrelevantWhileOtherTabsRemain() {
        let session = makeSession()
        let first = session.ensureTab()
        let second = session.addTab()

        session.close(first, replaceWhenEmpty: false)
        #expect(session.tabs.map(\.id) == [second.id])
        #expect(session.selectedTab?.id == second.id)
    }

    /// An emptied session is reusable: visiting the workspace again gives it a
    /// terminal rather than showing nothing.
    @Test func emptiedSessionRehydratesOnNextVisit() {
        let session = makeSession()
        session.close(session.ensureTab(), replaceWhenEmpty: false)
        #expect(session.isEmpty)

        let revived = session.ensureTab()
        #expect(session.tabs.count == 1)
        #expect(session.selectedTab?.id == revived.id)
    }

    // MARK: New tabs inherit the working directory

    /// ⌘T beside a terminal sitting in a directory starts the new shell there,
    /// not in the home directory.
    @Test func newTabInheritsTheWorkingDirectoryOfTheCurrentTab() {
        let session = makeSession()
        let first = session.ensureTab()
        first.panes?.focusedController?
            .updateCurrentDirectory("kitty-shell-cwd://localhost/Users/ventz/git/moo-mac-terminal")

        let added = session.addTab()
        #expect(added.panes?.focusedController?.pendingLaunchDirectory
                == "/Users/ventz/git/moo-mac-terminal")
    }

    /// With inheritance switched off in General settings the new shell falls
    /// back to the plain launch, which lands in the home directory.
    @Test func newTabIgnoresTheWorkingDirectoryWhenInheritanceIsOff() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "newTabsUseCurrentDirectory")
        defaults.set(false, forKey: "newTabsUseCurrentProfile")
        defer {
            defaults.removeObject(forKey: "newTabsUseCurrentDirectory")
            defaults.removeObject(forKey: "newTabsUseCurrentProfile")
        }

        let session = makeSession()
        let first = session.ensureTab()
        first.panes?.focusedController?
            .updateCurrentDirectory("kitty-shell-cwd://localhost/Users/ventz/git")

        let added = session.addTab()
        #expect(added.panes?.focusedController?.pendingLaunchDirectory == nil)
    }

    /// A shell that never reported OSC 7 has nothing to pass on, and the new
    /// tab must still open rather than fail.
    @Test func newTabFallsBackWhenTheSourceNeverReportedADirectory() {
        let session = makeSession()
        session.ensureTab()
        let added = session.addTab()
        #expect(added.panes?.focusedController?.pendingLaunchDirectory == nil)
    }

    /// With a Markdown preview or browser tab on screen, ⌘T copies the last
    /// terminal's directory instead of giving up.
    @Test func newTabInheritsFromTheLastTerminalWhileAWebTabIsShowing() {
        let session = makeSession()
        let terminal = session.ensureTab()
        terminal.panes?.focusedController?
            .updateCurrentDirectory("kitty-shell-cwd://localhost/Users/ventz/git")
        session.addTab(web: StubWebContent())

        let added = session.addTab()
        #expect(added.panes?.focusedController?.pendingLaunchDirectory == "/Users/ventz/git")
    }

    // MARK: Sidebar visibility belongs to one window

    /// cmd+B in one window must leave every other window as it was.
    @Test func togglingTheSidebarOnlyAffectsThatWindow() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: ProjectSidebarDefaults.isVisible)
        defer { defaults.removeObject(forKey: ProjectSidebarDefaults.isVisible) }
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)

        runtime.toggleSidebar(in: first)

        #expect(first.isSidebarVisible)
        #expect(!second.isSidebarVisible)
    }

    /// The last choice is still remembered, but only as a starting point.
    @Test func aNewWindowStartsWithTheLastSidebarChoice() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: ProjectSidebarDefaults.isVisible)
        defer { defaults.removeObject(forKey: ProjectSidebarDefaults.isVisible) }
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        runtime.register(first)

        runtime.toggleSidebar(in: first)

        #expect(WindowScope().isSidebarVisible)
    }

    // MARK: Closing a window ends what it held

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// A session is never kept alive without a window to reach it from. That
    /// is also what keeps a new window from adopting a terminal whose shell
    /// already exited: the session went with its window.
    @Test func closingAWindowEndsOnlyTheWorkspaceItShows() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let closingWindow = makeWindow()
        let otherWindow = makeWindow()
        let closing = WindowScope()
        closing.window = closingWindow
        let other = WindowScope()
        other.window = otherWindow
        runtime.register(closing)
        runtime.register(other)
        let one = UUID()
        let two = UUID()
        runtime.select(projectID: one, in: closing)
        runtime.select(projectID: two, in: other)

        #expect(runtime.sessionsEnded(byClosing: closingWindow).map(\.projectID) == [one])
        runtime.windowWillClose(closingWindow)

        #expect(runtime.existingSession(for: one) == nil)
        #expect(runtime.existingSession(for: two) != nil)
        #expect(closing.isClosed)
        #expect(closing.selectedProjectID == nil)
        #expect(runtime.scopes.map(\.id) == [other.id])
    }

    /// With no window left, the workspaces switched away from in the sidebar
    /// have nothing to reach them from either, so they end too.
    @Test func closingTheLastWindowEndsEveryWorkspace() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let window = makeWindow()
        let scope = WindowScope()
        scope.window = window
        runtime.register(scope)
        let background = UUID()
        let shown = UUID()
        runtime.select(projectID: background, in: scope)
        runtime.select(projectID: shown, in: scope)

        #expect(Set(runtime.sessionsEnded(byClosing: window).map(\.projectID)) == [background, shown])
        runtime.windowWillClose(window)

        #expect(runtime.existingSession(for: background) == nil)
        #expect(runtime.existingSession(for: shown) == nil)
    }

    /// Settings, sheets and panels close too. They hold no workspace.
    @Test func closingAWindowWithoutAWorkspaceEndsNothing() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let terminalWindow = makeWindow()
        let scope = WindowScope()
        scope.window = terminalWindow
        runtime.register(scope)
        let id = UUID()
        runtime.select(projectID: id, in: scope)
        let settings = makeWindow()

        #expect(runtime.sessionsEnded(byClosing: settings).isEmpty)
        runtime.windowWillClose(settings)

        #expect(runtime.existingSession(for: id) != nil)
        #expect(!scope.isClosed)
    }

    @Test func closePromptSaysWhatWillEnd() {
        #expect(WindowClosePrompt.message(endingTabs: 1, projects: 1, processRunning: false)
                == "Its shell will be ended.")
        #expect(WindowClosePrompt.message(endingTabs: 3, projects: 1, processRunning: true)
                == "Its 3 tabs will be closed and their shells ended. A process is still running.")
        #expect(WindowClosePrompt.message(endingTabs: 4, projects: 2, processRunning: false)
                == "This is the last window, so the shells in all 2 projects will be ended.")
    }

    /// The exiting terminal's own window is found even when another is key.
    @Test func aTerminalResolvesToTheWindowItIsIn() throws {
        let runtime = ProjectRuntime(startsProcesses: false)
        let first = WindowScope()
        let second = WindowScope()
        runtime.register(first)
        runtime.register(second)
        let one = UUID()
        let two = UUID()
        runtime.select(projectID: one, in: first)
        runtime.select(projectID: two, in: second)
        let controller = try #require(runtime.session(for: one).selectedTab?.controllers.first)

        #expect(runtime.scope(showing: controller) === first)
    }
}
