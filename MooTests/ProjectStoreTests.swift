import Foundation
import Testing
@testable import Moo

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MooProjectTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ProjectsMigratorTests {
    @Test func currentDocumentRoundTrips() throws {
        let projects = [
            Project(
                id: UUID(),
                name: "moo",
                accentColor: ProfileColor(hex: "#7aa2f7"),
                sortIndex: 0
            ),
            Project(id: UUID(), name: "notes", sortIndex: 1)
        ]
        let migrator = ProjectsMigrator()
        let data = try migrator.encodeCurrent(projects)

        #expect(try migrator.sourceVersion(in: data) == migrator.currentVersion)
        let decoded = try migrator.decode(data, from: migrator.currentVersion)
        #expect(decoded == projects)
    }

    /// A version-less array is treated as a v0 document, so a hand-written or
    /// pre-release file still loads.
    @Test func decodesVersionlessArrayAsV0() throws {
        let raw = """
            [{"id":"11111111-1111-1111-1111-111111111111","name":"legacy","sortIndex":0,"rowOptions":{}}]
            """.data(using: .utf8)!
        let migrator = ProjectsMigrator()
        #expect(try migrator.sourceVersion(in: raw) == 0)
        let decoded = try migrator.decode(raw, from: 0)
        #expect(decoded.count == 1)
        #expect(decoded[0].name == "legacy")
    }

    /// Fields added after a document was written must not fail decoding.
    @Test func toleratesMissingOptionalFields() throws {
        let raw = """
            {"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"sparse"}]}
            """.data(using: .utf8)!
        let decoded = try ProjectsMigrator().decode(raw, from: 1)
        #expect(decoded[0].sortIndex == 0)
        #expect(decoded[0].rowOptions == .inherited)
    }

    @Test func trimsNames() throws {
        let raw = """
            {"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"  padded  "}]}
            """.data(using: .utf8)!
        let decoded = try ProjectsMigrator().decode(raw, from: 1)
        #expect(decoded[0].name == "padded")
    }

    /// A project written before it became a pure label may still carry a
    /// "directory" key. It must decode, ignoring the dead field.
    @Test func ignoresLegacyDirectoryField() throws {
        let raw = """
            {"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"legacy","directory":"/tmp/old"}]}
            """.data(using: .utf8)!
        let decoded = try ProjectsMigrator().decode(raw, from: 1)
        #expect(decoded.count == 1)
        #expect(decoded[0].name == "legacy")
    }

    @Test func rejectsUnnamedProject() throws {
        let migrator = ProjectsMigrator()
        #expect(throws: (any Error).self) {
            try migrator.validate([Project(name: "")])
        }
    }

    @Test func rejectsDuplicateIdentifiers() throws {
        let id = UUID()
        let migrator = ProjectsMigrator()
        #expect(throws: (any Error).self) {
            try migrator.validate([
                Project(id: id, name: "one"),
                Project(id: id, name: "two")
            ])
        }
    }

    @Test func rejectsFutureSchema() throws {
        let raw = #"{"version":99,"projects":[]}"#.data(using: .utf8)!
        let migrator = ProjectsMigrator()
        #expect(try migrator.sourceVersion(in: raw) == 99)
        #expect(throws: (any Error).self) {
            try migrator.decode(raw, from: 99)
        }
    }
}

@MainActor
final class ProjectStoreTests {
    @Test func addPersistsAcrossReload() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        let project = try store.add(name: "moo")

        #expect(store.projects.count == 1)

        let reopened = ProjectStore(directory: directory)
        #expect(reopened.projects.count == 1)
        #expect(reopened.projects[0].id == project.id)
        #expect(reopened.projects[0].name == "moo")
    }

    @Test func rejectsBlankAndDuplicateNames() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        try store.add(name: "alpha")

        #expect(throws: (any Error).self) { try store.add(name: "   ") }
        // Duplicate detection is case-insensitive.
        #expect(throws: (any Error).self) { try store.add(name: "ALPHA") }
        #expect(store.projects.count == 1)
    }

    @Test func updateRenamesButStillRejectsCollisions() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        let alpha = try store.add(name: "alpha")
        try store.add(name: "beta")

        var renamed = alpha
        renamed.name = "gamma"
        try store.update(renamed)
        #expect(store.project(withID: alpha.id)?.name == "gamma")

        var collides = renamed
        collides.name = "beta"
        #expect(throws: (any Error).self) { try store.update(collides) }
        // The rejected write must not have disturbed the catalog.
        #expect(store.project(withID: alpha.id)?.name == "gamma")
    }

    @Test func deleteRemovesFromDisk() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        let project = try store.add(name: "temporary")
        try store.delete(project.id)

        #expect(store.projects.isEmpty)
        #expect(ProjectStore(directory: directory).projects.isEmpty)
    }

    @Test func reorderRenumbersAndPersists() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        let a = try store.add(name: "a")
        let b = try store.add(name: "b")
        let c = try store.add(name: "c")

        try store.reorder(to: [c.id, a.id, b.id])
        #expect(store.projects.map(\.id) == [c.id, a.id, b.id])
        #expect(ProjectStore(directory: directory).projects.map(\.id) == [c.id, a.id, b.id])
    }

    /// A corrupt file must surface as a recovery issue and leave the store
    /// read-only rather than silently starting empty and overwriting the file.
    @Test func corruptFileReportsIssueAndBlocksWrites() throws {
        let directory = try makeTemporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("projects.json"))

        let issueCenter = PersistenceIssueCenter()
        let store = ProjectStore(directory: directory, issueCenter: issueCenter)

        #expect(store.projects.isEmpty)
        #expect(issueCenter.issues.contains { $0.domain == .projects })
        #expect(throws: (any Error).self) { try store.add(name: "blocked") }
    }

    @Test func missingFileStartsCleanWithNoIssue() throws {
        let issueCenter = PersistenceIssueCenter()
        let store = ProjectStore(
            directory: try makeTemporaryDirectory(),
            issueCenter: issueCenter
        )
        #expect(store.projects.isEmpty)
        #expect(issueCenter.issues.isEmpty)
    }
}

final class ProjectModelTests {
    /// The sidebar subtitle abbreviates whatever directory the terminal
    /// reports; nothing about the path is stored on the project.
    @Test func pathAbbreviationUsesHome() {
        let home = NSHomeDirectory()
        #expect("\(home)/git/thing".abbreviatedPath == "~/git/thing")
        #expect("/tmp/elsewhere".abbreviatedPath == "/tmp/elsewhere")
    }

    @Test func rowOptionsFallBackToGlobalDefaults() {
        let global = ProjectRowVisibility(
            showsStatus: true,
            showsBranch: false,
            showsPath: true,
            showsAccent: true
        )
        var project = Project(name: "p")
        project.rowOptions.showsBranch = true   // override the global "off"
        project.rowOptions.showsPath = false    // override the global "on"

        let resolved = global.resolved(for: project)
        #expect(resolved.showsStatus)           // inherited
        #expect(resolved.showsBranch)           // overridden on
        #expect(!resolved.showsPath)            // overridden off
        #expect(resolved.showsAccent)           // inherited
    }
}

final class ProjectStatusTests {
    /// Display priority: a program asking for the user outranks unread output,
    /// which outranks a merely running project, which outranks idle, which
    /// outranks a project that is not open.
    @Test func statusOrdering() {
        #expect(ProjectStatus.waiting > ProjectStatus.attention)
        #expect(ProjectStatus.attention > ProjectStatus.running)
        #expect(ProjectStatus.running > ProjectStatus.idle)
        #expect(ProjectStatus.idle > ProjectStatus.cold)
    }

    @Test func coldReportHasNoAttention() {
        #expect(ProjectStatusReport.cold.status == .cold)
        #expect(ProjectStatusReport.cold.attentionCount == 0)
        #expect(ProjectStatusReport.cold.source == .noSession)
    }
}

@MainActor
final class ProjectOrderingTests {
    /// Dragging a project changes its cmd+digit, because the shortcut is
    /// positional rather than stored on the project.
    @Test func reorderChangesPositionAndSurvivesReload() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        let first = try store.add(name: "first")
        let second = try store.add(name: "second")
        let third = try store.add(name: "third")

        #expect(store.projects.map(\.name) == ["first", "second", "third"])

        // Drag "third" to the top.
        try store.reorder(to: [third.id, first.id, second.id])
        #expect(store.projects.map(\.name) == ["third", "first", "second"])
        #expect(store.projects.map(\.sortIndex) == [0, 1, 2])
        #expect(ProjectStore(directory: directory).projects.map(\.name)
            == ["third", "first", "second"])
    }

    /// Projects added later must not sort ahead of earlier ones just because
    /// their names come first alphabetically.
    @Test func insertionOrderIsPreserved() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        try store.add(name: "zebra")
        try store.add(name: "apple")
        #expect(store.projects.map(\.name) == ["zebra", "apple"])
    }

    /// Identical sortIndex values (a hand-edited file) fall back to name order
    /// rather than an arbitrary one.
    @Test func tiesBreakByName() throws {
        let directory = try makeTemporaryDirectory()
        let raw = """
            {"version":1,"projects":[
              {"id":"22222222-2222-2222-2222-222222222222","name":"beta","sortIndex":0},
              {"id":"11111111-1111-1111-1111-111111111111","name":"alpha","sortIndex":0}
            ]}
            """
        try Data(raw.utf8).write(to: directory.appendingPathComponent("projects.json"))
        let store = ProjectStore(directory: directory)
        #expect(store.projects.map(\.name) == ["alpha", "beta"])
    }

    /// A reorder listing only some projects must not drop the others.
    @Test func partialReorderKeepsEveryProject() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        let a = try store.add(name: "a")
        try store.add(name: "b")
        try store.reorder(to: [a.id])
        #expect(store.projects.count == 2)
    }
}

final class CommandDigitsTargetTests {
    @Test func defaultsToProjects() {
        #expect(CommandDigitsTarget(rawValue: "projects") == .projects)
        #expect(CommandDigitsTarget(rawValue: "tabs") == .tabs)
        #expect(CommandDigitsTarget(rawValue: "nonsense") == nil)
    }
}

@MainActor
final class ProjectAutoNamingTests {
    /// cmd+N creates a project without a name, which then shows the directory
    /// its terminal is in.
    @Test func autoNamedProjectFollowsItsDirectory() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        let project = try store.addAutoNamed()

        #expect(project.isAutoNamed)
        #expect(project.displayName(directory: "/Users/someone/git/moo") == "moo")
        #expect(project.displayName(directory: "/tmp") == "tmp")
    }

    /// With no directory yet there is still something to show.
    @Test func autoNamedProjectFallsBackToItsPlaceholder() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        let project = try store.addAutoNamed()
        #expect(project.displayName(directory: nil) == project.name)
        #expect(!project.name.isEmpty)
    }

    /// Renaming pins the name so it stops tracking the directory.
    @Test func renamingStopsTheNameFollowingTheDirectory() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        var project = try store.addAutoNamed()

        project.name = "Assistants"
        project.isAutoNamed = false
        try store.update(project)

        let stored = try #require(store.project(withID: project.id))
        #expect(!stored.isAutoNamed)
        #expect(stored.displayName(directory: "/tmp") == "Assistants")
    }

    /// Several auto-named projects must not collide on the placeholder name.
    @Test func repeatedAutoNamingProducesUniqueNames() throws {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        let first = try store.addAutoNamed()
        let second = try store.addAutoNamed()
        let third = try store.addAutoNamed()

        #expect(Set([first.name, second.name, third.name]).count == 3)
        #expect(store.projects.count == 3)
    }

    /// A project written before auto-naming existed was named by hand, so it
    /// must not start following directories after an upgrade.
    @Test func legacyProjectsAreNotAutoNamed() throws {
        let raw = """
            {"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Assistants"}]}
            """.data(using: .utf8)!
        let decoded = try ProjectsMigrator().decode(raw, from: 1)
        #expect(!decoded[0].isAutoNamed)
        #expect(decoded[0].displayName(directory: "/tmp") == "Assistants")
    }

    @Test func autoNamingSurvivesAReload() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        let project = try store.addAutoNamed()

        let reopened = ProjectStore(directory: directory)
        #expect(reopened.project(withID: project.id)?.isAutoNamed == true)
    }
}

/// Covers the reorder arithmetic behind drag and drop. The bug these guard
/// against: dropping on the *top* half of a row used to move the project
/// *below* it, so the insertion line pointed one way and the drop went the
/// other.
@MainActor
final class ProjectDragReorderTests {
    private func makeStore(_ names: [String]) throws -> ProjectStore {
        let store = ProjectStore(directory: try makeTemporaryDirectory())
        for name in names {
            try store.add(name: name)
        }
        return store
    }

    /// The move a drop performs: remove, then insert relative to the target as
    /// it sits *after* the removal.
    private func reorder(
        _ store: ProjectStore,
        dragged: String,
        target: String,
        after: Bool
    ) throws {
        var ordered = store.projects
        guard let from = ordered.firstIndex(where: { $0.name == dragged }) else { return }
        let project = ordered.remove(at: from)
        guard let targetIndex = ordered.firstIndex(where: { $0.name == target }) else { return }
        ordered.insert(project, at: after ? targetIndex + 1 : targetIndex)
        try store.reorder(to: ordered.map(\.id))
    }

    /// Two rows, drag the first onto the *lower* half of the second: it should
    /// end up last.
    @Test func draggingDownOntoLowerHalfLandsBelow() throws {
        let store = try makeStore(["website", "api"])
        try reorder(store, dragged: "website", target: "api", after: true)
        #expect(store.projects.map(\.name) == ["api", "website"])
    }

    /// Same drag onto the *upper* half is a no-op in a two-row list: it was
    /// already above the target. Previously this swapped them.
    @Test func draggingDownOntoUpperHalfKeepsOrder() throws {
        let store = try makeStore(["website", "api"])
        try reorder(store, dragged: "website", target: "api", after: false)
        #expect(store.projects.map(\.name) == ["website", "api"])
    }

    @Test func draggingUpOntoUpperHalfLandsAbove() throws {
        let store = try makeStore(["a", "b", "c"])
        try reorder(store, dragged: "c", target: "a", after: false)
        #expect(store.projects.map(\.name) == ["c", "a", "b"])
    }

    @Test func draggingUpOntoLowerHalfLandsJustBelowTarget() throws {
        let store = try makeStore(["a", "b", "c"])
        try reorder(store, dragged: "c", target: "a", after: true)
        #expect(store.projects.map(\.name) == ["a", "c", "b"])
    }

    /// Dropping below the last row must be reachable — that is the whole
    /// reason the drop cares which half of the row it landed on.
    @Test func canDropAtTheVeryEnd() throws {
        let store = try makeStore(["a", "b", "c"])
        try reorder(store, dragged: "a", target: "c", after: true)
        #expect(store.projects.map(\.name) == ["b", "c", "a"])
    }

    @Test func middleReorderKeepsEveryProject() throws {
        let store = try makeStore(["a", "b", "c", "d"])
        try reorder(store, dragged: "b", target: "d", after: false)
        #expect(store.projects.map(\.name) == ["a", "c", "b", "d"])
        #expect(store.projects.count == 4)
    }

    @Test func reorderPersists() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProjectStore(directory: directory)
        for name in ["a", "b", "c"] { try store.add(name: name) }
        try reorder(store, dragged: "a", target: "c", after: true)

        #expect(ProjectStore(directory: directory).projects.map(\.name) == ["b", "c", "a"])
    }
}
