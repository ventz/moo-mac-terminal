//
//  WorkspaceRestore.swift
//  Moo
//
//  Brings workspaces back after a relaunch: each one's terminal tabs, its
//  split layout, and every pane's directory and profile. Shells start fresh.
//
//  Deliberately never saved: scrollback, command lines, environment and
//  titles. Those hold secrets and hostnames, and nothing reruns by itself.
//  Web tabs are not restored.
//
//  The file is a convenience, not user data: a corrupt or newer file is
//  ignored rather than surfaced in Settings > Data.
//

import Foundation
import os

enum WorkspaceRestoreDefaults {
    static let restoresOnLaunch = "restoresWorkspacesOnLaunch"
    static let defaultRestoresOnLaunch = true

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: restoresOnLaunch) as? Bool ?? defaultRestoresOnLaunch
    }
}

indirect enum SavedPane: Codable, Equatable {
    case terminal(directory: String?, profileID: UUID?, themeOverride: String?)
    case split(TerminalPaneSplit, SavedPane, SavedPane)

    /// Past these, splits are rebuilt as single panes, so a damaged file
    /// cannot recurse without end or start a storm of shells.
    static let maximumDepth = 8
    static let maximumPanes = 16
}

struct SavedTab: Codable, Equatable {
    var root: SavedPane
}

struct SavedWorkspace: Codable, Equatable {
    static let maximumTabs = 32

    var projectID: UUID
    var selectedTabIndex: Int
    var tabs: [SavedTab]
}

struct SavedWindow: Codable, Equatable {
    var projectID: UUID?
    var showsSidebar: Bool
}

struct WorkspaceRestoreDocument: Codable, Equatable {
    static let currentVersion = 1
    // Limits on what a file can ask for, damaged or not.
    static let maximumWindows = 16
    static let maximumWorkspaces = 128
    static let maximumFileBytes = 1_000_000
    /// Brackets deep. A real file is about 2 per split level plus 6.
    static let maximumNesting = 64

    var version = currentVersion
    var windows: [SavedWindow]
    var workspaces: [SavedWorkspace]
}

extension SavedPane {
    /// What a live pane tree looks like on disk.
    init(node: TerminalPaneNode) {
        switch node.content {
        case .terminal(let controller):
            self = .terminal(
                directory: controller.shellWorkingDirectory ?? controller.pendingLaunchDirectory,
                profileID: controller.profile.id,
                themeOverride: controller.themeOverride
            )
        case .split(let orientation, let first, let second):
            self = .split(orientation, SavedPane(node: first), SavedPane(node: second))
        }
    }
}

@MainActor
final class WorkspaceRestoreStore {
    let fileURL: URL
    private var lastWritten: Data?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.vpetkov.Moo",
        category: "WorkspaceRestore"
    )

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("WorkspaceRestore.json")
    }

    /// nil for a missing, unreadable, oversized, corrupt or newer file.
    func load() -> WorkspaceRestoreDocument? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Checked before decoding: the decoder recurses once per level.
        guard data.count <= WorkspaceRestoreDocument.maximumFileBytes,
              Self.nestingDepth(of: data) <= WorkspaceRestoreDocument.maximumNesting,
              let document = try? JSONDecoder().decode(WorkspaceRestoreDocument.self, from: data),
              document.version == WorkspaceRestoreDocument.currentVersion else {
            Self.logger.info("Ignoring an unreadable workspace restore file")
            return nil
        }
        lastWritten = data
        return document
    }

    /// Writes only when something changed. The file is created readable by
    /// the user alone and renamed into place, so it is never briefly 0644.
    func save(_ document: WorkspaceRestoreDocument) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document), data != lastWritten else { return }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            Self.logger.error("Could not save workspaces: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            lastWritten = data
        } catch {
            unlink(temporary.path)
            Self.logger.error("Could not save workspaces: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        unlink(fileURL.path)
        lastWritten = nil
    }

    /// The deepest bracket nesting outside strings.
    nonisolated static func nestingDepth(of data: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
    }
}

/// Where a restored shell may start: a directory the user owns, else the
/// home directory. Saved paths are the shell's real directory from the
/// kernel, already free of symlinks, so none are followed here.
enum RestoredDirectory {
    /// Network, removable and automounted locations: touching one at launch
    /// can hang the main thread on a server that is gone.
    static let unreachablePrefixes = [
        "/Volumes/", "/Network/", "/net/", "/home/",
        "/private/var/automount/", "/System/Volumes/Data/Volumes/", "/System/Volumes/Data/home/"
    ]

    static func validated(
        _ path: String,
        fileManager: FileManager = .default,
        userID: uid_t = getuid()
    ) -> String? {
        guard path.hasPrefix("/"), !path.contains("/../"),
              !unreachablePrefixes.contains(where: { path.hasPrefix($0) }),
              // Does not follow a final symlink: a link is refused, not
              // followed onto a mount that might hang.
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == userID else {
            return nil
        }
        return path
    }
}
