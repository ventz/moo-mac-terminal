import Foundation
import Testing
@testable import Tecolot

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
}
