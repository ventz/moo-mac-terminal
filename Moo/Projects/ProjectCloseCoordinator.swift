//
//  ProjectCloseCoordinator.swift
//  Moo
//
//  One place that decides what "close" means, so cmd+W, the red button, the
//  File menu and a shell exiting all behave the same way.
//
//  The rule: close the smallest thing that contains the terminal. A tab, when
//  the workspace has more than one. The workspace itself when that was its
//  last tab — which is a real loss, so it is confirmed first.
//

import AppKit
import Foundation

@MainActor
enum ProjectCloseOutcome {
    /// The request was dealt with here; the window must not close.
    case handled
    /// Nothing here owns this; let the window close as it normally would.
    case allowWindowClose
}

@MainActor
enum ProjectCloseCoordinator {
    /// - Parameter afterShellExit: true when the shell has already exited
    ///   (ctrl+D, `exit`) rather than the user asking to close. That terminal
    ///   is already dead, so declining the prompt has to leave a fresh tab
    ///   behind instead of a dead one.
    /// - Parameter scope: the window to act on. Defaults to the key window,
    ///   which is right for a menu command but wrong for a shell exiting in a
    ///   window behind it.
    static func closeSelected(
        afterShellExit: Bool = false,
        in scope: WindowScope? = nil,
        runtime: ProjectRuntime = .shared,
        store: ProjectStore = AppModel.shared.projects
    ) -> ProjectCloseOutcome {
        let scope = scope ?? runtime.keyScope
        // Any workspace with tabs owns the close of one of them, sidebar or
        // not: cmd+T creates in-app tabs regardless of the sidebar, so cmd+W
        // must take them away under the same rule — otherwise a close with
        // the sidebar hidden fell through to the window and killed every tab.
        guard let session = scope.selectedProjectID.flatMap(runtime.existingSession(for:)),
              let tab = session.selectedTab else {
            return .allowWindowClose
        }

        if session.tabs.count > 1 {
            session.close(tab)
            runtime.invalidate()
            return .handled
        }

        // A lone web tab is not a loss worth a prompt: close it and leave a
        // fresh terminal behind, as closing any last tab does.
        if !tab.isTerminal {
            session.close(tab)
            runtime.invalidate()
            return .handled
        }

        // The last terminal tab. Retiring the workspace is the sidebar's
        // business; with it hidden the window *is* the terminal, and closing
        // that is the window's, exactly as before workspaces existed.
        guard scope.isSidebarVisible,
              let projectID = scope.selectedProjectID,
              let project = store.project(withID: projectID) else {
            return .allowWindowClose
        }

        // Closing it retires the workspace, so ask first.
        //
        // The prompt is a sheet, not a modal alert: an app-modal alert blocks
        // the main thread, which freezes every other workspace's terminal
        // while it is up. That means the answer arrives asynchronously, so the
        // close is always vetoed here and acted on in the completion handler.
        guard let window = tab.controllers.first?.terminal?.window
            ?? NSApp.keyWindow else {
            return .allowWindowClose
        }

        confirmClosing(project, session: session, runtime: runtime, in: window) { confirmed in
            guard confirmed else {
                if afterShellExit {
                    // The shell is gone either way; give the workspace a live
                    // tab back rather than leaving a dead terminal on screen.
                    session.close(tab)
                    runtime.invalidate()
                }
                return
            }

            session.close(tab, replaceWhenEmpty: false)
            runtime.discardSession(for: projectID)
            try? store.delete(projectID)

            // Land somewhere sensible, or close the window if nothing is left.
            if let next = store.projects.first {
                runtime.select(projectID: next.id, in: scope)
            } else {
                window.close()
            }
        }
        return .handled
    }

    private static func confirmClosing(
        _ project: Project,
        session: WorkspaceSession,
        runtime: ProjectRuntime,
        in window: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        let name = project.displayName(
            directory: runtime.currentDirectory(for: project.id)
        )
        let alert = NSAlert()
        alert.messageText = "Close the project “\(name)”?"
        alert.informativeText = session.controllers.contains(
            where: TerminalClosePolicy.requiresConfirmation
        )
            ? "This was its last tab. A process is still running, and the project will be removed from the sidebar."
            : "This was its last tab, so the project will be removed from the sidebar."
        alert.addButton(withTitle: "Close Project")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
