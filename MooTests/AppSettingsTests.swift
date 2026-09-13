import Foundation
import Testing
@testable import Moo

@MainActor
struct AppSettingsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "moo-app-settings-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func sample(_ setting: AppSetting) -> Any {
        switch setting.kind {
        case .bool: return true
        case .int: return 4242
        case .double: return 150.0
        case .string: return "value-\(setting.key)"
        }
    }

    /// Export, write the file, read it back, import into a Mac whose every
    /// setting differs: each one comes out as exported.
    @Test func everySettingSurvivesAProfileFile() throws {
        let (source, sourceSuite) = makeDefaults()
        let (target, targetSuite) = makeDefaults()
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }
        for setting in AppSettings.all {
            source.set(sample(setting), forKey: setting.key)
            switch setting.kind {
            case .bool: target.set(false, forKey: setting.key)
            case .int: target.set(1, forKey: setting.key)
            case .double: target.set(9.5, forKey: setting.key)
            case .string: target.set("junk", forKey: setting.key)
            }
        }

        let data = try ProfileStore.encodedProfile(TerminalProfile(name: "Carrier"),
                                                   settings: AppSettings.snapshot(from: source))
        let embedded = try #require(ProfileStore.embeddedSettings(in: data))
        #expect(embedded.settings.count == AppSettings.all.count)
        AppSettings.apply(embedded.settings, to: target)

        for setting in AppSettings.all {
            switch setting.kind {
            case .bool: #expect(target.object(forKey: setting.key) as? Bool == true, "\(setting.key)")
            case .int: #expect(target.object(forKey: setting.key) as? Int == 4242, "\(setting.key)")
            case .double: #expect(target.object(forKey: setting.key) as? Double == 150, "\(setting.key)")
            case .string: #expect(target.string(forKey: setting.key) == "value-\(setting.key)", "\(setting.key)")
            }
        }
    }

    @Test func missingOrMistypedSettingsReturnToTheirDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "restoredRowsLimit")
        defaults.set(false, forKey: "useMetalRenderer")
        AppSettings.apply(["useMetalRenderer": .string("yes"), "fromTheFuture": .bool(true)], to: defaults)
        // Read the suite's own values: object(forKey:) falls back to the
        // defaults the app registered, which is what "returns to its default" means
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(stored["restoredRowsLimit"] == nil)
        #expect(stored["useMetalRenderer"] == nil)
        #expect(stored["fromTheFuture"] == nil)
    }

    @Test func startupProfileFollowsTheImportedProfile() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings.apply([AppSettings.startupProfileID: .string("OLD")], to: defaults, profileIDs: ["OLD": "NEW"])
        #expect(defaults.string(forKey: AppSettings.startupProfileID) == "NEW")
    }

    @Test func storedProfilesCarryNoSettings() throws {
        let data = try ProfileStore.encodedProfile(TerminalProfile(name: "Plain"))
        #expect(ProfileStore.embeddedSettings(in: data) == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"settings\""))
    }

    /// Every defaults key in Moo's source is either carried or deliberately
    /// excluded. A new setting fails here until it is added to AppSettings.all.
    @Test func everyDefaultsKeyInTheSourceIsAccountedFor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moo")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let patterns = [
            #"forKey:\s*"([A-Za-z][A-Za-z0-9]*)""#,
            #"AppStorage\(\s*"([A-Za-z][A-Za-z0-9]*)""#,
            #"let \w*(?:DefaultsKey|[a-z]Key)\s*=\s*"([A-Za-z][A-Za-z0-9]*)""#,
        ].map { try! NSRegularExpression(pattern: $0) }
        let enumStart = try NSRegularExpression(pattern: #"^(\s*)(?:\w+ )*enum \w*Defaults(?:Key)?\s*\{"#)
        let enumConstant = try NSRegularExpression(pattern: #"static let \w+\s*=\s*"([A-Za-z][A-Za-z0-9]*)""#)

        func captures(_ regex: NSRegularExpression, in text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }

        var found: Set<String> = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns { found.formUnion(captures(pattern, in: text)) }
            var closing: String?
            for line in text.components(separatedBy: "\n") {
                if let end = closing {
                    if line == end { closing = nil } else { found.formUnion(captures(enumConstant, in: line)) }
                } else if let match = enumStart.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                          let indent = Range(match.range(at: 1), in: line) {
                    closing = line[indent] + "}"
                }
            }
        }

        let carried = Set(AppSettings.all.map(\.key))
        #expect(carried.count == AppSettings.all.count, "a setting is listed twice")
        #expect(carried.isDisjoint(with: AppSettings.excludedKeys))
        #expect(found.subtracting(carried).subtracting(AppSettings.excludedKeys).sorted() == [],
                "add these to AppSettings.all, or to excludedKeys if they are not settings")
        #expect(found.contains("attentionSoundVolume") && found.contains("themeBrowserPlotMode"),
                "the source scan found nothing; check its path")
    }
}
