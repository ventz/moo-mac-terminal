//
//  ProjectSelection.swift
//  Tecolot
//
//  The single definition of "switch to this workspace", shared by the sidebar,
//  the Window menu and the cmd+digit shortcuts.
//
//  A switch changes only which workspace's terminals are attached to the
//  window's terminal area:
//
//    cmd+1 -> workspace 1's tabs;  cd /tmp
//    cmd+2 -> workspace 2's tabs;  cd /blah   (workspace 1 unaffected)
//    cmd+1 -> back to workspace 1, still at /tmp; a new tab here belongs to
//             workspace 1 and leaves its other tabs alone
//
//  No window is created, hidden or closed, so nothing that is running can be
//  disturbed by navigating between workspaces.
//

import AppKit
import Foundation

@MainActor
enum ProjectSelection {
    static func select(_ project: Project, runtime: ProjectRuntime = .shared) {
        runtime.select(projectID: project.id)
    }

    /// cmd+1...8: the Nth workspace in sidebar order.
    static func selectProject(at index: Int) {
        let projects = AppModel.shared.projects.projects
        guard projects.indices.contains(index) else { return }
        select(projects[index])
    }

    /// cmd+9: the last workspace, matching the tab shortcut's behavior.
    static func selectLastProject() {
        guard let project = AppModel.shared.projects.projects.last else { return }
        select(project)
    }
}
