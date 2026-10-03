import Foundation
import Testing
@testable import Moo

struct KeyboardShortcutCatalogTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let listedKeys = Set(
        KeyboardShortcutCatalog.groups.flatMap(\.shortcuts).flatMap(\.keys)
    )

    /// Every `.keyboardShortcut("x", modifiers: …)` in the app, as glyphs
    /// ("⇧⌘[") in the order macOS menus print them.
    private static func sourceShortcuts() throws -> [(glyphs: String, file: String)] {
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\(\s*(?:"((?:\\.|[^"])+)"|\.(\w+))\s*,\s*modifiers:\s*(\[[^\]]*\]|\.\w+)\s*\)"#
        )
        let names = ["upArrow": "↑", "downArrow": "↓", "leftArrow": "←", "rightArrow": "→", "return": "↩"]
        var found: [(String, String)] = []
        let sources = repository.appendingPathComponent("Moo")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                func group(_ index: Int) -> String? {
                    Range(match.range(at: index), in: text).map { String(text[$0]) }
                }
                guard let key = group(1)?.uppercased() ?? group(2).flatMap({ names[$0] }),
                      let modifiers = group(3) else { continue }
                let glyphs = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
                    .filter { modifiers.contains(".\($0.0)") }
                    .map(\.1)
                    .joined()
                found.append((glyphs + key, file.lastPathComponent))
            }
        }
        return found
    }

    @Test func everyMenuShortcutIsListed() throws {
        let shortcuts = try Self.sourceShortcuts()
        // The scan itself must work: a pattern that matched nothing would
        // pass the check below vacuously.
        #expect(shortcuts.count > 40, "scanned only \(shortcuts.count) shortcuts")
        #expect(shortcuts.contains { $0.glyphs == "⇧⌘[" })
        #expect(shortcuts.contains { $0.glyphs == "⌥⌘↑" })

        let missing = shortcuts.filter { !Self.listedKeys.contains($0.glyphs) }
        #expect(missing.isEmpty, "Not in KeyboardShortcutCatalog: \(missing)")
    }

    @Test func everyShortcutIsDocumented() throws {
        let doc = try String(
            contentsOf: Self.repository.appendingPathComponent("docs/SHORTCUTS.md"),
            encoding: .utf8
        )
        let undocumented = KeyboardShortcutCatalog.groups.flatMap { group in
            group.shortcuts
                .filter { !doc.contains("| \($0.displayKeys) | \($0.action) |") }
                .map { "\(group.title): \($0.displayKeys)" }
        }
        #expect(undocumented.isEmpty, "Not in docs/SHORTCUTS.md: \(undocumented)")
        for group in KeyboardShortcutCatalog.groups {
            #expect(doc.contains("## \(group.title)"), "no section for \(group.title)")
        }
    }

    /// The pair people mix up, pinned: ⇧⌘[ switches tabs, ⌘[ goes back.
    @Test func tabAndBackShortcutsStayDistinct() {
        let groups = Dictionary(uniqueKeysWithValues: KeyboardShortcutCatalog.groups.map { ($0.title, $0) })
        #expect(groups["Tabs"]?.shortcuts.contains { $0.keys == ["⇧⌘[", "⇧⌘]"] } == true)
        #expect(groups["Markdown Previews"]?.shortcuts.contains { $0.keys == ["⌘[", "⌘]"] } == true)
        #expect(groups["Browser Tabs"]?.shortcuts.contains { $0.keys == ["⌘[", "⌘]"] } == true)
    }

    @Test func noKeyIsListedTwiceInOneGroup() {
        for group in KeyboardShortcutCatalog.groups {
            let keys = group.shortcuts.flatMap(\.keys)
            #expect(Set(keys).count == keys.count, "duplicate in \(group.title)")
        }
    }
}
