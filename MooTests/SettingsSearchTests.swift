import Foundation
import Testing
@testable import Moo

@MainActor
struct SettingsSearchTests {
    @Test func findsASettingByAWordItDoesNotShow() {
        let results = SettingsSearch.results(for: "transparency")
        #expect(results.contains { $0.destination == .text })
        #expect(results.flatMap(\.entries).contains { $0.title == "Background opacity:" })
    }

    @Test func everyWordMustMatch() {
        let titles = SettingsSearch.results(for: "tab opaque").flatMap(\.entries).map(\.title)
        #expect(titles.contains("Keep the tab strip opaque"))
        #expect(!titles.contains("Keep the projects sidebar opaque"))
    }

    @Test func resultsFollowSidebarOrder() {
        let pages = SettingsSearch.results(for: "opaque").map(\.destination)
        let order = SettingsDestination.allCases
        #expect(pages == pages.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }

    @Test func blankQueryIsNotASearch() {
        #expect(!SettingsSearch.isSearching("  "))
        #expect(SettingsSearch.results(for: "  ").isEmpty)
    }

    /// The sidebar groups by scope: app-wide first, then the profile pages,
    /// then updates and data. Every page is in exactly one group.
    @Test func everyPageIsInOneSidebarGroup() {
        let grouped = SettingsDestination.Group.allCases.flatMap(\.destinations)
        #expect(grouped == SettingsDestination.allCases)
        #expect(SettingsDestination.Group.profile.destinations.allSatisfy {
            $0 == .profiles || $0.isProfileDriven
        })
        #expect(SettingsDestination.Group.app.destinations.allSatisfy { !$0.isProfileDriven })
    }

    /// A control with a literal label added to a settings page fails here
    /// until it is listed in SettingsSearch.entries, so search never silently
    /// misses it. A label built at run time ("Long means at least 10
    /// seconds") cannot be matched; index those by hand.
    @Test func everySettingsControlIsSearchable() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moo/Settings")
        // Controls inside row editors (key mappings, environment variables,
        // the project list, the rename alert), not settings of their own.
        let editorControls: Set<String> = [
            "Unset", "Command", "Shift", "Option", "Control", "Action", "Name", "Key", "Value",
        ]
        let pattern = try NSRegularExpression(
            pattern: #"(?:Toggle|Picker|Stepper|TextField|Slider|ColorPicker)\(\s*"([^"\\]+)""#
        )
        let indexed = Set(SettingsSearch.entries.map(\.title))
        var missing: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let labelRange = Range(match.range(at: 1), in: source) else { continue }
                let label = String(source[labelRange])
                if !editorControls.contains(label), !indexed.contains(label) {
                    missing.append("\(file.lastPathComponent): \(label)")
                }
            }
        }
        #expect(missing.isEmpty, "Not in SettingsSearch.entries: \(missing)")
    }

    /// Choosing a result scrolls to and outlines its setting, which needs an
    /// anchor with the entry's page and title on that setting. An entry for
    /// a whole page (titled like the page, e.g. Data) has nothing to outline.
    @Test func everySearchResultHasAnAnchor() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moo/Settings")
        var source = ""
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            source += try String(contentsOf: file, encoding: .utf8)
        }
        let unanchored = SettingsSearch.entries
            .filter { $0.title != $0.destination.title || $0.destination == .projects || $0.destination == .profiles }
            .filter { entry in
                let name = "\(entry.destination)"
                return !source.contains(".settingsAnchor(.\(name), \"\(entry.title)\")")
            }
            .map(\.id)
        #expect(unanchored.isEmpty, "No .settingsAnchor for: \(unanchored)")
    }

    /// Each page's help button opens its section of docs/SETTINGS.md; the
    /// anchor must be GitHub's slug of a real heading, or the link lands at
    /// the top of the doc. Slugs follow GitHub: lowercase, punctuation other
    /// than hyphens dropped, spaces to hyphens, repeats suffixed -1, -2, ….
    @Test func everyPageHelpLinkPointsAtAHeading() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/SETTINGS.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        var seen: [String: Int] = [:]
        var anchors: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("#") {
            let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            var slug = String(heading.lowercased().compactMap { character -> Character? in
                if character == " " { return "-" }
                if character == "-" || character.isLetter || character.isNumber { return character }
                return nil
            })
            if let count = seen[slug] {
                seen[slug] = count + 1
                slug += "-\(count + 1)"
            } else {
                seen[slug] = 0
            }
            anchors.insert(slug)
        }
        for destination in SettingsDestination.allCases {
            #expect(anchors.contains(destination.documentationAnchor), "\(destination.title): #\(destination.documentationAnchor)")
        }
    }

    @Test func aResultFlashesOnlyWhileItsRequestIsFresh() {
        let highlight = SettingsHighlight()
        let id = SettingsSearch.Entry.anchorID(.links, "Follow the terminal theme")
        #expect(!highlight.isPending(id))
        highlight.reveal(id)
        #expect(highlight.isPending(id))
        #expect(!highlight.isPending(SettingsSearch.Entry.anchorID(.general, "Draw with Metal")))
        #expect(!highlight.isPending(id, now: Date().addingTimeInterval(5)))
    }

    /// docs/SETTINGS.md documents every searchable setting by its label. A
    /// new setting fails here until it is documented, and since the test
    /// above ties every control to the search index, every control is
    /// documented too.
    @Test func everySettingIsDocumented() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/SETTINGS.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let headings = Set(text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") }
            .map { $0.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) })
        // The label in bold, as the tables write it, or a section heading
        // for a whole-section entry. A bare substring would pass on any
        // sentence that happens to use the words.
        let undocumented = SettingsSearch.entries
            .map { $0.title.hasSuffix(":") ? String($0.title.dropLast()) : $0.title }
            .filter { !text.contains("**\($0)**") && !text.contains("**\($0):**") && !headings.contains($0) }
        #expect(undocumented.isEmpty, "Not in docs/SETTINGS.md: \(undocumented)")
    }
}

@MainActor
struct CommandDigitsChoiceTests {
    private func defaults() -> UserDefaults {
        let name = "CommandDigitsChoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func roundTripsEveryChoiceThroughTheTwoKeys() {
        for choice in CommandDigitsChoice.allCases {
            let defaults = defaults()
            choice.store(in: defaults)
            #expect(CommandDigitsChoice.current(defaults) == choice)
        }
    }

    /// The old pair "tabs" + "don't use ⌘1–9 for tabs" reads as Nothing, and
    /// a fresh install reads as Projects, as before.
    @Test func readsExistingSettings() {
        let fresh = defaults()
        #expect(CommandDigitsChoice.current(fresh) == .projects)

        let tabsOff = defaults()
        tabsOff.set(CommandDigitsTarget.tabs.rawValue, forKey: ProjectSidebarDefaults.commandDigitsTarget)
        tabsOff.set(false, forKey: CommandDigitsChoice.selectsTabsKey)
        #expect(CommandDigitsChoice.current(tabsOff) == .off)
    }
}

@MainActor
struct UpdateAlertModeTests {
    private func defaults() -> UserDefaults {
        let name = "UpdateAlertModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Before the three-way choice, Sparkle's switch was the only one: a Mac
    /// that had turned automatic checks off must not start checking again.
    @Test func followsSparklesSwitchUntilChosen() {
        let fresh = defaults()
        #expect(UpdateAlertMode.current(fresh, sparkleChecksAutomatically: true) == .window)
        #expect(UpdateAlertMode.current(fresh, sparkleChecksAutomatically: false) == .off)
        fresh.set(UpdateAlertMode.dot.rawValue, forKey: UpdateDefaults.alertMode)
        #expect(UpdateAlertMode.current(fresh, sparkleChecksAutomatically: false) == .dot)
    }

    @Test func quietCheckRunsOnceADay() {
        let now = Date()
        #expect(UpdateAlertMode.quietCheckIsDue(lastCheck: nil, now: now))
        #expect(!UpdateAlertMode.quietCheckIsDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        #expect(UpdateAlertMode.quietCheckIsDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
    }
}
