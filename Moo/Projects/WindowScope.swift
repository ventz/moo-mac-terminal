//
//  WindowScope.swift
//  Moo
//
//  One window's view of the workspaces. Selection lives here rather than on
//  ProjectRuntime because a terminal's NSView can only be in one view
//  hierarchy: when every window read one global selection, a second window
//  rendered the same session and pulled the live view out of the first, which
//  was left as an empty frame.
//
//  A workspace is therefore shown by at most one window at a time. Selecting
//  one that another window already has brings that window forward instead of
//  moving it, which is both what the user meant and what keeps the view where
//  it is.
//

import AppKit
import Observation

@Observable
@MainActor
final class WindowScope: Identifiable {
    nonisolated let id = UUID()

    /// The workspace this window is showing.
    var selectedProjectID: UUID?

    /// Whether this window shows the projects sidebar. Per window, so cmd+B in
    /// one window leaves the others alone. A new window starts from the last
    /// choice made in any window.
    var isSidebarVisible = UserDefaults.standard.bool(forKey: ProjectSidebarDefaults.isVisible)

    /// The ⌘K palette is open over this window.
    var isPaletteVisible = false

    /// Set once the window starts closing. Its view renders no terminal from
    /// then on, so tearing the workspace down cannot start a shell in it.
    var isClosed = false

    /// The window this scope belongs to, set once the view is in one. Weak:
    /// the scope must not keep a closed window alive.
    @ObservationIgnored weak var window: NSWindow?

    var session: WorkspaceSession? {
        selectedProjectID.map { ProjectRuntime.shared.session(for: $0) }
    }
}
