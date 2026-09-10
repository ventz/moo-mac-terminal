//
//  ProjectStore.swift
//  Moo
//
//  Persists the project catalog. Modeled on WindowGroupStore: a versioned
//  JSON document in Application Support, loaded through VersionedFileLoader
//  so a corrupt or future-versioned file is backed up and surfaced in
//  Settings > Data rather than silently discarded.
//
//  This store holds definitions only. Live windows and sessions belong to
//  ProjectRuntime and are never written here.
//

import Combine
import Foundation

private struct ProjectsDocumentV1: Codable {
    var version: Int
    var projects: [Project]
}

struct ProjectsMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        // A version-less file is a hand-written or pre-release document.
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> [Project] {
        let projects: [Project]
        switch sourceVersion {
        case 0:
            projects = try JSONDecoder().decode([Project].self, from: data)
        case 1:
            projects = try JSONDecoder().decode(ProjectsDocumentV1.self, from: data).projects
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported project schema.")
        }
        return projects.map { project in
            var project = project
            project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return project
        }
    }

    func validate(_ projects: [Project]) throws {
        guard projects.allSatisfy({ !$0.name.isEmpty }) else {
            throw VersionedPersistenceError.invalidDocument("A project has no name.")
        }
        guard Set(projects.map(\.id)).count == projects.count else {
            throw VersionedPersistenceError.invalidDocument("Two projects share an identifier.")
        }
    }

    func encodeCurrent(_ projects: [Project]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ProjectsDocumentV1(version: currentVersion, projects: projects))
    }
}

enum ProjectError: LocalizedError {
    case invalidName
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a name for the project."
        case let .duplicateName(name):
            return "A project named \"\(name)\" already exists."
        }
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    private let fileURL: URL
    private let directory: URL
    private let backupDirectory: URL
    private let issueCenter: PersistenceIssueCenter?
    private var isReadOnly = false

    init(
        directory: URL? = nil,
        issueCenter: PersistenceIssueCenter? = nil,
        backupDirectory: URL? = nil
    ) {
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        fileURL = base.appendingPathComponent("projects.json")
        self.backupDirectory = backupDirectory ?? base.appendingPathComponent("Backups")
        self.issueCenter = issueCenter
        load()
    }

    // MARK: Lookup

    func project(withID id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    // MARK: Mutation

    /// Creates a project without asking for a name. It shows its terminal's
    /// directory until renamed, so one keystroke is enough to start working.
    @discardableResult
    func addAutoNamed() throws -> Project {
        try ensureWritable()
        var candidate = "New Project"
        var suffix = 2
        while projects.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
        }) {
            candidate = "New Project \(suffix)"
            suffix += 1
        }
        let project = Project(
            name: candidate,
            sortIndex: (projects.map(\.sortIndex).max() ?? -1) + 1,
            isAutoNamed: true
        )
        try mutate { $0.append(project) }
        return project
    }

    @discardableResult
    func add(name: String) throws -> Project {
        try ensureWritable()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw ProjectError.invalidName }
        guard !projects.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ProjectError.duplicateName(normalizedName)
        }

        let project = Project(
            name: normalizedName,
            sortIndex: (projects.map(\.sortIndex).max() ?? -1) + 1
        )
        try mutate { $0.append(project) }
        return project
    }

    func update(_ project: Project) throws {
        try ensureWritable()
        let normalizedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw ProjectError.invalidName }
        guard !projects.contains(where: {
            $0.id != project.id
                && $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ProjectError.duplicateName(normalizedName)
        }

        var updated = project
        updated.name = normalizedName
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.id == updated.id }) else { return }
            list[index] = updated
        }
    }

    func delete(_ id: UUID) throws {
        try ensureWritable()
        try mutate { $0.removeAll { $0.id == id } }
    }

    /// Applies a new sidebar order, renumbering sortIndex to match.
    func reorder(to orderedIDs: [UUID]) throws {
        try ensureWritable()
        try mutate { list in
            let position = Dictionary(
                uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) }
            )
            for index in list.indices {
                if let sortIndex = position[list[index].id] {
                    list[index].sortIndex = sortIndex
                }
            }
        }
    }

    /// Runs a mutation against a copy, persists it, and rolls back on failure
    /// so the in-memory catalog never drifts from what is on disk.
    private func mutate(_ body: (inout [Project]) -> Void) throws {
        let previous = projects
        var working = projects
        body(&working)
        projects = Self.sorted(working)
        do {
            try persist()
        } catch {
            projects = previous
            reportWriteFailure(error)
            throw error
        }
    }

    // MARK: Persistence

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            isReadOnly = true
            projects = []
            issueCenter?.replaceIssues(in: .projects, with: [PersistenceIssue(
                domain: .projects,
                sourceURL: fileURL,
                kind: .unreadable,
                message: error.localizedDescription,
                supportedVersion: ProjectsMigrator().currentVersion
            )])
            return
        }

        let result = VersionedFileLoader.load(
            from: fileURL,
            domain: .projects,
            backupRoot: backupDirectory,
            migrator: ProjectsMigrator()
        )
        isReadOnly = result.issue != nil
        projects = Self.sorted(result.value ?? [])
        issueCenter?.replaceIssues(in: .projects, with: result.issue.map { [$0] } ?? [])
    }

    private func persist() throws {
        let data = try ProjectsMigrator().encodeCurrent(projects)
        try data.write(to: fileURL, options: .atomic)
        issueCenter?.resolve(domain: .projects, sourceURL: fileURL)
    }

    private func reportWriteFailure(_ error: Error) {
        issueCenter?.report(PersistenceIssue(
            domain: .projects,
            sourceURL: fileURL,
            kind: .writeFailed,
            message: error.localizedDescription,
            supportedVersion: ProjectsMigrator().currentVersion
        ))
    }

    private func ensureWritable() throws {
        guard !isReadOnly else {
            throw PersistenceMutationError.recoveryRequired(.projects)
        }
    }

    private static func sorted(_ projects: [Project]) -> [Project] {
        projects.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "net.vpetkov.Moo")
    }
}
