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
    /// What this tab holds: a terminal split tree, or web content.
    let content: WorkspaceTabContent
    /// Fallback label, used until the shell posts a title of its own.
    var title: String

    /// A terminal tab. The split tree owns its terminal session controllers.
    init(startsProcesses: Bool = true, title: String = "Terminal") {
        content = .terminal(TerminalPaneWorkspace(startsProcesses: startsProcesses))
        self.title = title
    }

    /// A web tab, holding a markdown preview or a browser session.
    init(web content: any WebTabContent) {
        self.content = .web(content)
        title = content.displayTitle
    }

    var kind: WorkspaceTabKind { content.kind }

    var isTerminal: Bool {
        if case .terminal = content { return true }
        return false
    }

    /// The split tree, for terminal tabs. Web tabs have none.
    var panes: TerminalPaneWorkspace? {
        if case .terminal(let panes) = content { return panes }
        return nil
    }

    /// The web content, for web tabs. Terminal tabs have none.
    var web: (any WebTabContent)? {
        if case .web(let content) = content { return content }
        return nil
    }

    /// Every session controller in this tab. Empty for web tabs, which is
    /// what keeps them out of status, quit confirmation and close prompts.
    var controllers: [TerminalSessionController] {
        panes?.controllers ?? []
    }

    /// What the tab strip shows: the terminal's own title when it has posted
    /// one, exactly as the native tab bar displayed it.
    var displayTitle: String {
        switch content {
        case .web(let web):
            let trimmed = web.displayTitle.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? title : trimmed
        case .terminal(let panes):
            let posted = (panes.focusedController ?? panes.controllers.first)?.tabTitle ?? ""
            let trimmed = posted.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            if let directory = currentDirectory {
                let name = (directory as NSString).lastPathComponent
                return name.isEmpty ? directory : name
            }
            return title
        }
    }

    /// The directory this tab's focused terminal is in, from OSC 7 — or the
    /// directory a web tab relates to.
    var currentDirectory: String? {
        switch content {
        case .web(let web):
            return web.currentDirectory
        case .terminal(let panes):
            return panes.focusedController?.currentWorkingDirectory
                ?? panes.controllers.compactMap(\.currentWorkingDirectory).first
        }
    }

    /// Kills this tab's shells, or releases its web content. Only ever
    /// called from an explicit close.
    func terminate() {
        switch content {
        case .terminal(let panes): panes.terminateAll()
        case .web(let web): web.terminate()
        }
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

    /// The terminal tab that was most recently on screen. While a web tab is
    /// selected the window keeps this one's terminals attached (hidden), so
    /// switching back is instant and no shell is ever started just to fill
    /// the space behind a preview. Falls back to any terminal tab.
    var mostRecentTerminalTab: WorkspaceTab? {
        if let selected = selectedTab, selected.isTerminal { return selected }
        if let remembered = tabs.first(where: { $0.id == mostRecentTerminalTabID }) {
            return remembered
        }
        return tabs.first(where: \.isTerminal)
    }

    @ObservationIgnored private var mostRecentTerminalTabID: UUID?

    var isEmpty: Bool { tabs.isEmpty }

    /// A workspace always shows something, so the first visit creates a tab.
    @discardableResult
    func ensureTab() -> WorkspaceTab {
        if let existing = selectedTab { return existing }
        return addTab()
    }

    /// Adds a terminal tab and selects it.
    @discardableResult
    func addTab() -> WorkspaceTab {
        insert(WorkspaceTab(startsProcesses: startsProcesses))
    }

    /// Adds a web tab — a markdown preview or a browser — and selects it.
    @discardableResult
    func addTab(web content: any WebTabContent) -> WorkspaceTab {
        insert(WorkspaceTab(web: content))
    }

    private func insert(_ tab: WorkspaceTab) -> WorkspaceTab {
        // A new tab goes right after the current one, as browsers do, so a
        // preview opened from a terminal lands beside it rather than at the
        // far end of a long strip.
        if let current = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: current + 1)
        } else {
            tabs.append(tab)
        }
        select(tab)
        return tab
    }

    func select(_ tab: WorkspaceTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        setSelected(tab.id)
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        setSelected(tabs[index].id)
    }

    private func setSelected(_ id: UUID?) {
        selectedTabID = id
        if let tab = tabs.first(where: { $0.id == id }), tab.isTerminal {
            mostRecentTerminalTabID = id
        }
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

        if mostRecentTerminalTabID == tab.id {
            mostRecentTerminalTabID = nil
        }

        if tabs.isEmpty {
            if replaceWhenEmpty {
                addTab()
            } else {
                setSelected(nil)
            }
            return
        }
        if selectedTabID == tab.id {
            setSelected(tabs[min(index, tabs.count - 1)].id)
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
        setSelected(tabs[next].id)
    }

    /// Every session controller in the workspace, across all tabs and splits.
    /// Web tabs contribute nothing.
    var controllers: [TerminalSessionController] {
        tabs.flatMap(\.controllers)
    }

    /// The terminal tab containing a controller, if any.
    func tab(containing controller: TerminalSessionController) -> WorkspaceTab? {
        tabs.first { tab in tab.controllers.contains { $0 === controller } }
    }

    func terminateAll() {
        for tab in tabs {
            tab.terminate()
        }
        tabs.removeAll()
        selectedTabID = nil
    }
}
