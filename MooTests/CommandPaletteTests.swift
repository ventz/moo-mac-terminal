import AppKit
import Testing
@testable import Moo

@MainActor
final class CommandPaletteTests {
    @Test func screenMatchesComeNewestFirstWithoutOverlaps() {
        let rows = [
            "see https://example.com/a?b=1).",
            "commit 3f9a2c1d is on main, deadbeef is not",
            "edit src/main.swift:12 and ~/notes.md",
            "ping 10.0.0.1:8080"
        ]
        let matches = QuickSelectMatcher.matches(inRows: rows)
        #expect(matches.first == QuickSelectMatch(kind: .address, text: "10.0.0.1:8080"))
        #expect(matches.contains(QuickSelectMatch(kind: .path, text: "src/main.swift:12")))
        #expect(matches.contains(QuickSelectMatch(kind: .path, text: "~/notes.md")))
        #expect(matches.contains(QuickSelectMatch(kind: .hash, text: "3f9a2c1d")))
        #expect(matches.contains(QuickSelectMatch(kind: .url, text: "https://example.com/a?b=1")))
        #expect(!matches.contains { $0.text == "deadbeef" })
        // The link's own path is not offered again.
        #expect(!matches.contains { $0.kind == .path && $0.text.contains("example.com") })
    }

    @Test func repeatsAreDroppedAndTheListIsCapped() {
        #expect(QuickSelectMatcher.matches(inRows: Array(repeating: "https://moo.test", count: 100)).count == 1)
        let many = (0..<100).map { "https://moo.test/\($0)" }
        #expect(QuickSelectMatcher.matches(inRows: many).count == QuickSelectMatcher.limit)
    }

    @Test func hiddenCharactersNeverReachTheClipboard() {
        #expect(QuickSelectMatcher.sanitized("abc\u{202E}def\u{07}") == "abcdef")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MooTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        QuickSelectAction.copy(QuickSelectMatch(kind: .hash, text: "3f9a2c1d"), concealed: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "3f9a2c1d")
        #expect(pasteboard.types?.contains(QuickSelectAction.concealedType) == true)
    }

    @Test func linksWithCredentialsAreConcealed() {
        #expect(QuickSelectAction.carriesCredentials(QuickSelectMatch(kind: .url, text: "https://me:hunter2@moo.test")))
        #expect(!QuickSelectAction.carriesCredentials(QuickSelectMatch(kind: .url, text: "https://moo.test/a")))
        #expect(!QuickSelectAction.carriesCredentials(QuickSelectMatch(kind: .path, text: "me@host:/tmp")))
    }

    @Test func pathologicalRowsStayCheap() {
        let started = Date()
        let rows = Array(repeating: String(repeating: "a.", count: 20_000), count: 40)
        _ = QuickSelectMatcher.matches(inRows: rows)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func shortcutsReadAsInMenus() {
        #expect(MenuCommandCollector.shortcutText(key: "d", modifiers: [.command, .shift]) == "⇧⌘D")
        #expect(MenuCommandCollector.shortcutText(key: "\r", modifiers: [.command, .shift]) == "⇧⌘↩")
        #expect(MenuCommandCollector.shortcutText(key: "k", modifiers: [.command, .option]) == "⌥⌘K")
        #expect(MenuCommandCollector.shortcutText(key: "", modifiers: [.command]) == "")
        let f5 = String(UnicodeScalar(UInt32(NSF5FunctionKey))!)
        #expect(MenuCommandCollector.shortcutText(key: f5, modifiers: [.command]) == "⌘F5")
    }

    private final class Target: NSObject {
        var runs = 0
        @objc func fire(_ sender: Any?) { runs += 1 }
    }

    @Test func commandsAreReadFromTheMenusAndRunThroughThem() {
        let target = Target()
        let terminal = NSMenu(title: "Terminal")
        terminal.autoenablesItems = false
        let split = NSMenuItem(title: "Split Pane", action: #selector(Target.fire(_:)), keyEquivalent: "d")
        split.target = target
        terminal.addItem(split)
        let disabled = NSMenuItem(title: "Unzoom Pane", action: #selector(Target.fire(_:)), keyEquivalent: "")
        disabled.isEnabled = false
        terminal.addItem(disabled)
        terminal.addItem(.separator())
        let hidden = NSMenuItem(title: "Hidden", action: #selector(Target.fire(_:)), keyEquivalent: "")
        hidden.isHidden = true
        terminal.addItem(hidden)
        terminal.addItem(NSMenuItem(title: CommandPaletteModel.menuTitle, action: #selector(Target.fire(_:)), keyEquivalent: "k"))
        let alternate = NSMenuItem(title: "Split Pane Twice", action: #selector(Target.fire(_:)), keyEquivalent: "d")
        alternate.keyEquivalentModifierMask = [.command, .option]
        alternate.isAlternate = true
        alternate.target = target
        terminal.addItem(alternate)

        let main = NSMenu(title: "Main")
        let terminalItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        terminalItem.submenu = terminal
        main.addItem(terminalItem)

        let commands = MenuCommandCollector.commands(in: main)
        #expect(commands.map(\.title) == ["Split Pane"])
        #expect(commands.first?.path == "Terminal")
        #expect(commands.first?.shortcut == "⌘D")

        // Runs even after the menu that held the item is gone.
        terminal.removeAllItems()
        commands.first?.run()
        #expect(target.runs == 1)
    }

    @Test func typingFiltersAndTitlesStartingWithTheQueryLead() {
        func command(_ title: String, _ path: String = "Terminal") -> PaletteCommand {
            PaletteCommand(id: title, title: title, path: path, shortcut: "") {}
        }
        let model = CommandPaletteModel(
            matches: [QuickSelectMatch(kind: .path, text: "src/split.swift")],
            commands: [command("Equalize Split", "Window"), command("Split Pane"), command("Clear Scrollback")]
        )
        #expect(model.items.count == 4)

        model.query = "split"
        let titles = model.items.map { item -> String in
            switch item {
            case .match(let match): return match.text
            case .command(let command): return command.title
            }
        }
        // Typed queries put commands before anything printed on screen.
        #expect(titles == ["Split Pane", "Equalize Split", "src/split.swift"])

        model.query = "window split"
        #expect(model.items.count == 1)

        model.query = ""
        model.moveSelection(by: -1)
        #expect(model.selection == 3)
        model.moveSelection(by: 1)
        #expect(model.selection == 0)
    }
}
