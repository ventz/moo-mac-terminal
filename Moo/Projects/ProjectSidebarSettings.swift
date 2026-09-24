//
//  ProjectSidebarSettings.swift
//  Moo
//
//  App-wide sidebar preferences: width and row options. Visibility is the
//  exception — each window shows or hides its own sidebar (WindowScope), and
//  the stored value is only what a newly opened window starts with.
//

import SwiftUI

enum ProjectSidebarDefaults {
    /// Whether a *new* window opens with the sidebar. Each open window keeps
    /// its own state in WindowScope.isSidebarVisible.
    static let isVisible = "projectsSidebarVisible"
    static let width = "projectsSidebarWidth"
    static let showsStatus = "projectsSidebarShowsStatus"
    static let showsBranch = "projectsSidebarShowsBranch"
    static let showsPath = "projectsSidebarShowsPath"
    static let showsAccent = "projectsSidebarShowsAccent"
    /// A hairline between the sidebar and the terminal. On by default; off
    /// gives the seamless look, where only the sidebar's shading sets it apart.
    static let drawsDivider = "projectsSidebarDrawsDivider"
    static let selectedProjectID = "projectsSidebarSelectedProjectID"
    /// "projects" or "tabs" — what cmd+1...9 selects.
    static let commandDigitsTarget = "projectsCommandDigitsTarget"

    static let minimumWidth: Double = 110
    static let maximumWidth: Double = 420
    /// Deliberately narrow: the sidebar is a navigator, and the terminal is
    /// what the window is for. Rows truncate at this width and surface their
    /// full text on hover instead.
    static let defaultWidth: Double = 150

    /// Registered in MooApp.init alongside the other app defaults.
    static let registrationValues: [String: Any] = [
        isVisible: false,
        width: defaultWidth,
        showsStatus: true,
        showsBranch: true,
        showsPath: true,
        showsAccent: true,
        drawsDivider: true,
        commandDigitsTarget: CommandDigitsTarget.projects.rawValue
    ]

    /// Keys the preference migrator should carry across schema versions.
    static let managedKeys: [String] = [
        isVisible, width, showsStatus, showsBranch, showsPath, showsAccent,
        selectedProjectID, commandDigitsTarget
    ]
}

/// What the cmd+digit shortcuts select. Projects and tabs cannot both own
/// cmd+1...9, so this is an explicit choice rather than a guess.
enum CommandDigitsTarget: String, CaseIterable, Identifiable {
    case projects
    case tabs

    var id: Self { self }

    var title: String {
        switch self {
        case .projects: return "Projects"
        case .tabs: return "Tabs"
        }
    }

    static var current: CommandDigitsTarget {
        let raw = UserDefaults.standard.string(forKey: ProjectSidebarDefaults.commandDigitsTarget)
        return raw.flatMap(CommandDigitsTarget.init(rawValue:)) ?? .projects
    }
}

/// Resolves the four optional row elements, letting a project override the
/// app-wide default. Constructed per render from @AppStorage values.
struct ProjectRowVisibility {
    var showsStatus: Bool
    var showsBranch: Bool
    var showsPath: Bool
    var showsAccent: Bool

    func resolved(for project: Project) -> ProjectRowVisibility {
        ProjectRowVisibility(
            showsStatus: project.rowOptions.showsStatus ?? showsStatus,
            showsBranch: project.rowOptions.showsBranch ?? showsBranch,
            showsPath: project.rowOptions.showsPath ?? showsPath,
            showsAccent: project.rowOptions.showsAccent ?? showsAccent
        )
    }
}
