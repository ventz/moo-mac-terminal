//
//  ProjectCommands.swift
//  Moo
//
//  Menu surface for workspaces: the sidebar toggle in the View menu, and the
//  workspace list plus management commands in the Window menu.
//

import AppKit
import SwiftUI

struct ProjectCommands: Commands {
    @ObservedObject var store: ProjectStore

    @AppStorage(ProjectSidebarDefaults.isVisible) private var sidebarIsVisible = false

    var body: some Commands {
        // The sidebar toggle belongs in the View menu, where macOS users look
        // for it. cmd+B matches cmux, VS Code and Cursor. It is technically
        // reserved for Bold in the HIG, which a terminal has no use for.
        CommandGroup(before: .sidebar) {
            Button(sidebarIsVisible ? "Hide Projects" : "Show Projects") {
                sidebarIsVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command])
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Menu("Projects") {
                ForEach(store.projects) { project in
                    Button(displayName(for: project)) { ProjectSelection.select(project) }
                }
                if !store.projects.isEmpty {
                    Divider()
                }
                Button("New Project…", action: addProject)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private func displayName(for project: Project) -> String {
        project.displayName(
            directory: ProjectRuntime.shared.currentDirectory(for: project.id)
        )
    }

    private func addProject() {
        sidebarIsVisible = true
        ProjectCommandActions.addNamedProject(store: store)
    }
}

/// Shared by the Window menu and cmd+N, which both create a project.
@MainActor
enum ProjectCommandActions {
    /// True when the workspace UI is on screen. cmd+N only means "new project"
    /// while the user is actually working in workspaces; with the sidebar
    /// closed it keeps its usual meaning of a new window.
    static var isWorkspaceUIOpen: Bool {
        UserDefaults.standard.bool(forKey: ProjectSidebarDefaults.isVisible)
    }

    /// cmd+N. Creates a project without prompting: it takes its name from the
    /// directory its terminal lands in, and keeps that until renamed.
    static func addProjectWithoutPrompting(store: ProjectStore) {
        do {
            ProjectSelection.select(try store.addAutoNamed())
        } catch {
            present(error)
        }
    }

    /// The menu entry, which does ask for a name.
    static func addNamedProject(store: ProjectStore) {
        guard let name = ProjectPrompt.askForName(
            title: "New Project",
            message: "A project is a label for a set of terminal tabs. "
                + "Its path and branch follow the terminals as you move around."
        ) else { return }
        do {
            UserDefaults.standard.set(true, forKey: ProjectSidebarDefaults.isVisible)
            ProjectSelection.select(try store.add(name: name))
        } catch {
            present(error)
        }
    }

    private static func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could Not Add Project"
        alert.runModal()
    }
}

/// SwiftUI's CommandsBuilder tops out at ten items and the app's list is
/// already full, so the two arrangement-related command sets travel together.
struct ArrangementCommands: Commands {
    @ObservedObject var windowGroups: WindowGroupStore
    @ObservedObject var projects: ProjectStore

    var body: some Commands {
        WindowGroupCommands(store: windowGroups)
        ProjectCommands(store: projects)
        MarkdownPreviewCommands()
        BrowserCommands()
    }
}
