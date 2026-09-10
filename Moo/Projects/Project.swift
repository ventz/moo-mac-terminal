//
//  Project.swift
//  Moo
//
//  A project is a label — a virtual organization unit, not a saved folder.
//  It groups terminals under a name the user chooses.
//
//  What is persisted is only the label itself: name, color, order. The path
//  and git branch shown in the sidebar are NOT stored; they are derived live
//  from wherever the project's terminals currently are, so a `cd` in the
//  terminal is reflected in the sidebar. A row is a projection of live state,
//  not a record of it.
//

import Foundation

/// Which optional elements a project's sidebar row shows. Each is nil by
/// default, meaning "follow the app-wide setting"; a non-nil value is an
/// explicit per-project override.
struct ProjectRowOptions: Codable, Equatable, Sendable {
    var showsStatus: Bool?
    var showsBranch: Bool?
    var showsPath: Bool?
    var showsAccent: Bool?

    static let inherited = ProjectRowOptions()

    var isInherited: Bool { self == .inherited }
}

struct Project: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// The label. This is the only user-authored content on a project.
    var name: String
    /// Launch defaults used only when opening a window for a label that has
    /// none yet. A label with live terminals never consults these.
    var profileID: UUID?
    var themeOverride: String?
    /// Row accent, reusing the app's existing Codable color primitive.
    var accentColor: ProfileColor?
    /// Explicit ordering in the sidebar; ties break by name.
    var sortIndex: Int
    var rowOptions: ProjectRowOptions
    /// True while the project has never been named by hand. Such a project
    /// shows the directory its terminal is in, so a project created with one
    /// keystroke still reads as something specific until it is renamed.
    var isAutoNamed: Bool

    init(
        id: UUID = UUID(),
        name: String,
        profileID: UUID? = nil,
        themeOverride: String? = nil,
        accentColor: ProfileColor? = nil,
        sortIndex: Int = 0,
        rowOptions: ProjectRowOptions = .inherited,
        isAutoNamed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.themeOverride = themeOverride
        self.accentColor = accentColor
        self.sortIndex = sortIndex
        self.rowOptions = rowOptions
        self.isAutoNamed = isAutoNamed
    }

    /// Tolerates older documents that predate a field, so adding one does not
    /// require a schema bump.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        themeOverride = try container.decodeIfPresent(String.self, forKey: .themeOverride)
        accentColor = try container.decodeIfPresent(ProfileColor.self, forKey: .accentColor)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        rowOptions = try container.decodeIfPresent(
            ProjectRowOptions.self,
            forKey: .rowOptions
        ) ?? .inherited
        // Projects written before auto-naming existed were named by hand.
        isAutoNamed = try container.decodeIfPresent(Bool.self, forKey: .isAutoNamed) ?? false
    }

    /// What the sidebar shows. An auto-named project follows its terminal's
    /// directory; once renamed, the chosen name wins and stops moving.
    func displayName(directory: String?) -> String {
        guard isAutoNamed, let directory, !directory.isEmpty else { return name }
        let leaf = (directory as NSString).lastPathComponent
        return leaf.isEmpty ? name : leaf
    }

    /// Launch parameters for opening a window on a label that has none yet.
    /// No working directory: a label does not own a location.
    @MainActor
    var launchSpec: LaunchSpec {
        LaunchSpec(profileID: profileID, themeOverride: themeOverride)
    }
}

extension String {
    /// "/Users/you/code/app" -> "~/code/app", for sidebar subtitles.
    var abbreviatedPath: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
