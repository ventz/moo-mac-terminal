//
//  ProjectSidebarSettings.swift
//  Moo
//
//  App-wide sidebar preferences. Every native tab is its own window with its
//  own ContentView, so sidebar visibility, width and row options have to be
//  shared state rather than per-window state — otherwise switching tabs would
//  flicker the sidebar in and out.
//

import SwiftUI

enum ProjectSidebarDefaults {
    static let isVisible = "projectsSidebarVisible"
    static let width = "projectsSidebarWidth"
    static let showsStatus = "projectsSidebarShowsStatus"
    static let showsBranch = "projectsSidebarShowsBranch"
    static let showsPath = "projectsSidebarShowsPath"
    static let showsAccent = "projectsSidebarShowsAccent"
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
