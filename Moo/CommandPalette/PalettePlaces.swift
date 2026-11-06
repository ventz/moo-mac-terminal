//
//  PalettePlaces.swift
//  Moo
//
//  ⌘K's tabs and workspaces: one row per workspace and one per tab, in
//  every window, found by tab title, workspace name, directory or the
//  program running in a pane. Choosing one brings that pane forward, in
//  whichever window holds it.
//
//  Only sessions that already exist are read, so listing never starts a
//  shell. A workspace from the last run not yet opened is searchable by the
//  directories it will reopen in.
//
//  Every string here was written by something else (a program's title, an
//  OSC 7 path, argv) and is already cleaned where it entered Moo.
//

import AppKit
import Foundation
import SwiftTerm

/// When each tab was last on screen, newest highest, so ⌘K lists the
/// tab just left first, as zsh's ⌃R lists the last command first. Kept in
/// memory only: it orders a list, nothing more.
@MainActor
enum PlaceRecency {
    private static var stamps: [UUID: Int] = [:]
    private static var clock = 0

    static func touch(_ tabID: UUID?) {
        guard let tabID else { return }
        clock += 1
        stamps[tabID] = clock
    }

    /// 0 for a tab never shown since launch.
    static func stamp(of tabID: UUID) -> Int { stamps[tabID] ?? 0 }

    static func reset() {
        stamps = [:]
        clock = 0
    }
}

struct PalettePlace: Identifiable {
    enum Kind: String {
        case workspace = "Workspace"
        case tab = "Tab"
        case preview = "Preview"
        case browser = "Browser"
    }

    /// A pane a search can land on. A tab with splits has several.
    struct Pane {
        let searchText: String
        let reveal: @MainActor () -> Void
    }

    let id: String
    let kind: Kind
    let title: String
    /// Where it is: the workspace, and the directory.
    let subtitle: String
    let searchText: String
    /// The tab or workspace already on screen in this window.
    let isCurrent: Bool
    let panes: [Pane]
    let reveal: @MainActor () -> Void
    /// From PlaceRecency; 0 when never shown, and for workspace rows.
    var lastUsed: Int = 0
    /// A workspace row whose workspace has tabs open (each has its own row).
    var hasOpenTabs = false

    /// Lands on the pane the query matched, so searching for "vim" in a tab
    /// split three ways focuses the split running vim.
    @MainActor
    func reveal(matching query: String) {
        let words = query.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty, panes.count > 1,
           let pane = panes.first(where: { PaletteFilter.accepts($0.searchText, query: words) }) {
            pane.reveal()
        } else {
            reveal()
        }
    }
}

@MainActor
enum PalettePlaceCollector {
    static func places(runtime: ProjectRuntime, projects: [Project], scope: WindowScope) -> [PalettePlace] {
        var result: [PalettePlace] = []
        for project in projects {
            let session = runtime.existingSession(for: project.id)
            let name = project.displayName(directory: session?.selectedTab?.currentDirectory)
            let isShown = scope.selectedProjectID == project.id
            let tabs = session?.tabs ?? []
            let savedDirectories = tabs.isEmpty ? runtime.savedDirectories(for: project.id) : []
            let directories = tabs.compactMap(\.currentDirectory) + savedDirectories
            let tabCount = tabs.count
            let summary = tabCount == 0
                ? (savedDirectories.isEmpty ? "" : "not opened yet")
                : "\(tabCount) \(tabCount == 1 ? "tab" : "tabs")"
            let selectWorkspace: @MainActor () -> Void = { [scope] in
                NSApp.activate(ignoringOtherApps: true)
                runtime.select(projectID: project.id, in: scope)
            }
            result.append(PalettePlace(
                id: "workspace:\(project.id.uuidString)",
                kind: .workspace,
                title: name,
                subtitle: summary,
                searchText: ([name, "workspace"] + directories + directories.map(\.abbreviatedPath))
                    .joined(separator: " "),
                isCurrent: isShown,
                panes: [],
                reveal: selectWorkspace,
                hasOpenTabs: tabCount > 0
            ))

            guard let session else { continue }
            for tab in tabs {
                result.append(place(for: tab, in: session, projectID: project.id, workspaceName: name,
                                    isCurrent: isShown && session.selectedTab?.id == tab.id,
                                    runtime: runtime, scope: scope))
            }
        }
        return result
    }

    private static func place(for tab: WorkspaceTab,
                              in session: WorkspaceSession,
                              projectID: UUID,
                              workspaceName: String,
                              isCurrent: Bool,
                              runtime: ProjectRuntime,
                              scope: WindowScope) -> PalettePlace {
        let kind: PalettePlace.Kind
        switch tab.kind {
        case .terminal: kind = .tab
        case .markdown: kind = .preview
        case .browser: kind = .browser
        }
        let panes: [PalettePlace.Pane] = tab.controllers.map { controller in
            let directory = controller.displayedWorkingDirectory
            let text = [controller.tabTitle, controller.foregroundProgram ?? "",
                        directory ?? "", directory?.abbreviatedPath ?? ""]
                .joined(separator: " ")
            return PalettePlace.Pane(searchText: text) { AttentionNavigator.reveal(controller) }
        }
        let selectTab: @MainActor () -> Void = { [weak tab, weak session, scope] in
            guard let tab, let session else { return }
            if let controller = tab.panes?.focusedController ?? tab.controllers.first {
                AttentionNavigator.reveal(controller)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            runtime.select(projectID: projectID, in: scope)
            session.select(tab)
            runtime.invalidate()
            (runtime.scope(showing: projectID)?.window ?? scope.window)?.makeKeyAndOrderFront(nil)
        }
        var subtitle = workspaceName
        if let directory = tab.currentDirectory {
            subtitle += " · \(directory.abbreviatedPath)"
        }
        if panes.count > 1 {
            subtitle += " · \(panes.count) splits"
        }
        let title = tab.displayTitle
        return PalettePlace(
            id: "tab:\(tab.id.uuidString)",
            kind: kind,
            title: title,
            subtitle: subtitle,
            searchText: ([title, workspaceName, kind.rawValue] + panes.map(\.searchText)
                         + [tab.currentDirectory ?? "", tab.currentDirectory?.abbreviatedPath ?? ""])
                .joined(separator: " "),
            isCurrent: isCurrent,
            panes: panes,
            reveal: selectTab,
            lastUsed: PlaceRecency.stamp(of: tab.id)
        )
    }
}

/// What ⌘K does with a directory.
@MainActor
enum DirectoryJump {
    /// The pane already in `path`, preferring the ones in `preferred`
    /// (the window's own workspace), so a jump reuses a tab before opening one.
    static func existingPane<Pane: AnyObject>(for path: String,
                                              among panes: [Pane],
                                              preferred: [Pane],
                                              directory: (Pane) -> String?) -> Pane? {
        let target = DirectoryPaths.normalized(path)
        return preferred.first { directory($0).map(DirectoryPaths.normalized) == target }
            ?? panes.first { directory($0).map(DirectoryPaths.normalized) == target }
    }

    /// The text typed for "cd here". ⌃E ⌃U first clears what is half typed
    /// on the line, or the cd would be appended to it. The leading space
    /// keeps it out of history for shells set to ignore such lines.
    ///
    /// **No Return is sent** (security review, 2026-11-05): Moo cannot see
    /// the edit buffer. A pasted multi-line command not yet run, an open
    /// quote on a continuation prompt, or a vi keymap where ⌃U kills less
    /// would all run text the user never confirmed. The user reads the line
    /// and presses Return.
    ///
    /// Only plain paths are typed: letters, digits, space and `/._-+,@~=:`.
    /// Single quotes are not literal in every shell (fish reads `\'` inside
    /// them, tcsh expands `!`), so anything else returns nil and the caller
    /// opens a tab there instead, with nothing typed.
    static let clearLine = "\u{05}\u{15}"

    static func cdCommand(for path: String) -> String? {
        guard DirectoryPaths.isAcceptable(path), isPlain(path) else { return nil }
        return "\(clearLine) cd -- '\(path)'"
    }

    static func isPlain(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || " /._-+,@~=:".unicodeScalars.contains(scalar)
        }
    }

    /// Smart jump: switch to a pane already there, else open a tab there.
    /// "There" is the kernel's word, never OSC 7: any output, an ssh host
    /// included, can report a local-looking directory, and bringing that
    /// pane forward would have the user typing into the remote host. A pane
    /// running a program (ssh, vim) is not "in" a directory for this.
    static func go(to path: String, scope: WindowScope, runtime: ProjectRuntime? = nil) {
        let runtime = runtime ?? .shared
        let preferred = scope.session?.controllers ?? []
        let target = DirectoryPaths.resolved(path) ?? path
        if let pane = existingPane(for: target, among: runtime.allControllers, preferred: preferred,
                                   directory: { $0.shellOwnsTerminal ? $0.shellWorkingDirectory : nil }) {
            AttentionNavigator.reveal(pane)
            return
        }
        FinderServiceActions.openTab(in: path, runtime: runtime)
    }

    /// Types `cd` into the pane, only while its shell holds the terminal.
    /// Returns false when it did not, so the caller can fall back.
    static func changeDirectory(of controller: TerminalSessionController?, to path: String) -> Bool {
        guard let controller, controller.shellOwnsTerminal,
              let command = cdCommand(for: path),
              let terminal = controller.terminal else { return false }
        terminal.send(txt: command)
        return true
    }
}
