//
//  WorkspaceSession.swift
//  Tecolot
//
//  The live contents of one workspace: its tabs, and which one is showing.
//
//  These objects are owned by ProjectRuntime, deliberately *outside* the
//  SwiftUI view tree. That is the whole point: SwiftUI is free to build and
//  tear down views as it likes, and a workspace that is not on screen keeps
//  its terminals and their shells running regardless. Switching workspaces
//  detaches terminal views and re-attaches them later, exactly as splitting a
//  pane already does, so no process is ever restarted by navigation.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceTab: Identifiable {
    let id = UUID()
    /// The split tree for this tab. Owns its terminal session controllers.
    let panes: TerminalPaneWorkspace
    /// Fallback label, used until the shell posts a title of its own.
    var title: String

    init(startsProcesses: Bool = true, title: String = "Terminal") {
        panes = TerminalPaneWorkspace(startsProcesses: startsProcesses)
        self.title = title
    }

    /// What the tab strip shows: the terminal's own title when it has posted
    /// one, exactly as the native tab bar displayed it.
    var displayTitle: String {
        let posted = (panes.focusedController ?? panes.controllers.first)?.tabTitle ?? ""
        let trimmed = posted.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if let directory = currentDirectory {
            let name = (directory as NSString).lastPathComponent
            return name.isEmpty ? directory : name
        }
        return title
    }

    /// The directory this tab's focused terminal is in, from OSC 7.
    var currentDirectory: String? {
        panes.focusedController?.currentWorkingDirectory
            ?? panes.controllers.compactMap(\.currentWorkingDirectory).first
    }

    /// Kills this tab's shells. Only ever called from an explicit close.
    func terminate() {
        panes.terminateAll()
    }
}

@Observable
@MainActor
final class WorkspaceSession {
    let projectID: UUID
    private(set) var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?

    /// The workspace's current status, recomputed by ProjectRuntime's poll.
    ///
    /// Stored here rather than derived on demand so SwiftUI observes *this*
    /// value: a row re-renders only when its own status changes, instead of
    /// every row redrawing whenever anything in the app ticks.
    var status: ProjectStatusReport = .cold

    @ObservationIgnored private let startsProcesses: Bool

    init(projectID: UUID, startsProcesses: Bool = true) {
        self.projectID = projectID
        self.startsProcesses = startsProcesses
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var isEmpty: Bool { tabs.isEmpty }

    /// A workspace always shows something, so the first visit creates a tab.
    @discardableResult
    func ensureTab() -> WorkspaceTab {
        if let existing = selectedTab { return existing }
        return addTab()
    }

    @discardableResult
    func addTab() -> WorkspaceTab {
        let tab = WorkspaceTab(startsProcesses: startsProcesses)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func select(_ tab: WorkspaceTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedTabID = tab.id
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    /// Closes a tab and terminates its shells.
    ///
    /// By default, closing the last tab leaves a fresh one in its place so a
    /// workspace always has a usable terminal. Pass `replaceWhenEmpty: false`
    /// when the caller intends the workspace itself to go away.
    func close(_ tab: WorkspaceTab, replaceWhenEmpty: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.terminate()

        if tabs.isEmpty {
            if replaceWhenEmpty {
                addTab()
            } else {
                selectedTabID = nil
            }
            return
        }
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by offset: Int) {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            return
        }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    /// Every session controller in the workspace, across all tabs and splits.
    var controllers: [TerminalSessionController] {
        tabs.flatMap(\.panes.controllers)
    }

    func terminateAll() {
        for tab in tabs {
            tab.terminate()
        }
        tabs.removeAll()
        selectedTabID = nil
    }
}
