//
//  CommandPaletteView.swift
//  Moo
//
//  The command-K overlay. Return runs a command, goes to a tab or
//  directory, or copies a match; command-Return opens a match;
//  option-Return types `cd` to a directory into the pane, at a prompt only.
//  Escape or a click outside closes. Arrow,
//  Return and Escape keys are taken with a local event monitor: a SwiftUI
//  text field hands arrows to its field editor before onKeyPress sees them.
//

import AppKit
import SwiftTerm
import SwiftUI

struct CommandPaletteView: View {
    let scope: WindowScope
    /// The terminal on screen, or nil while a web tab is.
    let controller: TerminalSessionController?
    let projects: [Project]

    @State private var model: CommandPaletteModel?
    @State private var keyMonitor: Any?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Clicking anywhere outside the card closes the palette.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            if let model {
                card(model)
                    .padding(.top, 36)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear(perform: open)
        // ⌘J while open: switch to directories, or close if already there.
        .onChange(of: scope.paletteQueryRequest) {
            guard let model else { return }
            if model.narrowing != .everything,
               model.narrowing == CommandPaletteModel.parse(scope.paletteInitialQuery).0 {
                scope.paletteInitialQuery = ""
                close()
            } else {
                model.query = scope.paletteInitialQuery
                scope.paletteInitialQuery = ""
                placeCaretAtEnd(of: model.query, attemptsLeft: 10)
            }
        }
        // However it closed (Escape, command-K again, a tab switch), put the
        // keyboard back in the terminal, if that pane is still on screen.
        .onDisappear {
            removeKeyMonitor()
            if controller?.terminal?.window != nil {
                controller?.requestFocus()
            }
        }
    }

    private func card(_ model: CommandPaletteModel) -> some View {
        let items = model.items
        return VStack(spacing: 0) {
            TextField("Search tabs, directories, commands and what is on screen", text: Bindable(model).query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .focused($searchIsFocused)
                // A pass later: focus set before the field exists is dropped.
                .onAppear {
                    Task { @MainActor in searchIsFocused = true }
                }
                // Focusing selects the text; a prefilled "z " must be kept,
                // not replaced by the first key. Once the field editor holds
                // the query, put the caret after it, checked rather than
                // timed.
                .onChange(of: searchIsFocused) { _, focused in
                    guard focused, !model.query.isEmpty else { return }
                    placeCaretAtEnd(of: model.query, attemptsLeft: 10)
                }
            Divider()
            if items.isEmpty {
                Text("Nothing matches")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == model.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selection = index
                                        perform(item, opening: false)
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: model.selection) { _, selection in
                        if items.indices.contains(selection) {
                            proxy.scrollTo(items[selection].id)
                        }
                    }
                }
            }
            Divider()
            Text(hint(for: model.selectedItem))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 18)
    }


    private func open() {
        let rows = controller?.terminal?.terminalStateSnapshot().visibleRows.map(\.text) ?? []
        let model = CommandPaletteModel(
            matches: QuickSelectMatcher.matches(inRows: rows),
            commands: MenuCommandCollector.commands(in: NSApp.mainMenu),
            places: PalettePlaceCollector.places(runtime: .shared, projects: projects, scope: scope),
            directories: DirectoryHistory.shared.directories(
                includingOwn: CommandPaletteDefaults.remembersDirectories(),
                includingZshZ: CommandPaletteDefaults.readsZshZData()
            )
        )
        model.query = scope.paletteInitialQuery
        scope.paletteInitialQuery = ""
        self.model = model
        installKeyMonitor()
    }

    /// Waits for the field editor to show `query`, a bounded number of
    /// short turns, then moves the caret to its end.
    private func placeCaretAtEnd(of query: String, attemptsLeft: Int) {
        if let editor = scope.window?.firstResponder as? NSTextView, editor.string == query {
            editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            placeCaretAtEnd(of: query, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func hint(for item: CommandPaletteModel.Item?) -> String {
        switch item {
        case .directory:
            return controller == nil
                ? "↩ go there  ·  esc close"
                : "↩ go there  ·  ⌥↩ type cd here  ·  esc close"
        case .place:
            return "↩ go to it  ·  esc close  ·  z dirs, t tabs"
        default:
            return "↩ run or copy  ·  ⌘↩ open  ·  esc close  ·  z dirs, t tabs"
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// nil swallows the key.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let window = scope.window, event.window === window else { return event }
        // Composing text with an input method: Return and arrows belong to it.
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText(), event.keyCode != 53 {
            return event
        }
        switch event.keyCode {
        case 53: // escape
            close()
            return nil
        case 125: // down arrow
            model.moveSelection(by: 1)
            return nil
        case 126: // up arrow
            model.moveSelection(by: -1)
            return nil
        case 36, 76: // return, keypad enter
            if let item = model.selectedItem {
                perform(item,
                        opening: event.modifierFlags.contains(.command),
                        changingDirectory: event.modifierFlags.contains(.option))
            }
            return nil
        default:
            return event
        }
    }

    private func perform(_ item: CommandPaletteModel.Item, opening: Bool, changingDirectory: Bool = false) {
        let words = model?.searchWords ?? ""
        close()
        switch item {
        case .place(let place):
            place.reveal(matching: words)
        case .directory(let directory):
            // cd is typed (never run) only into a shell holding its terminal,
            // and only for a plain path; otherwise the jump opens a tab.
            if changingDirectory {
                if DirectoryJump.changeDirectory(of: controller, to: directory.path) { return }
                NSSound.beep()
            }
            DirectoryJump.go(to: directory.path, scope: scope)
        case .match(let match):
            if opening {
                LinkRouter.open(match.text, from: controller, forcesExternal: false)
            } else {
                QuickSelectAction.copy(
                    match,
                    concealed: SecureKeyboardEntry.shared.isProtectingPrompt
                        || QuickSelectAction.carriesCredentials(match)
                )
            }
        case .command(let command):
            // Once focus is back on the terminal the command acts on.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                command.run()
            }
        }
    }

    /// Focus goes back in onDisappear, which every way of closing reaches.
    private func close() {
        removeKeyMonitor()
        scope.isPaletteVisible = false
    }
}

/// One row of the palette.
struct PaletteRow: View {
    let item: CommandPaletteModel.Item
    let isSelected: Bool

    /// How each kind of row shows what it is: an icon, a color and a word,
    /// so a tab, a workspace and a directory never look alike (user,
    /// 2026-11-06: "crystal clear which is what"). Color is never the only
    /// cue; the word and the icon say it too.
    private struct Badge {
        let label: String
        let symbol: String
        let color: SwiftUI.Color

        static func of(_ item: CommandPaletteModel.Item) -> Badge {
            switch item {
            case .match(let match): return Badge(label: match.kind.rawValue, symbol: "text.viewfinder", color: .secondary)
            case .command: return Badge(label: "Command", symbol: "command", color: .secondary)
            case .directory: return Badge(label: "Directory", symbol: "folder.fill", color: .green)
            case .place(let place):
                switch place.kind {
                case .tab: return Badge(label: "Tab", symbol: "terminal.fill", color: .blue)
                case .workspace: return Badge(label: "Workspace", symbol: "square.stack.3d.up.fill", color: .orange)
                case .preview: return Badge(label: "Preview", symbol: "doc.richtext.fill", color: .purple)
                case .browser: return Badge(label: "Browser", symbol: "globe", color: .teal)
                }
            }
        }
    }

    private func badge(_ item: CommandPaletteModel.Item) -> some View {
        let badge = Badge.of(item)
        return HStack(spacing: 6) {
            Image(systemName: badge.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(badge.color)
                .frame(width: 18)
            Text(badge.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(badge.color.opacity(0.15), in: Capsule())
        }
        .frame(width: 104, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.label)
    }

    var body: some View {
        HStack(spacing: 8) {
            badge(item)
            switch item {
            case .match(let match):
                Text(match.text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    // Tail, not middle: a middle cut can hide a link's real host.
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            case .command(let command):
                Text(command.title)
                    .lineLimit(1)
                if !command.path.isEmpty {
                    Text(command.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(command.shortcut)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .place(let place):
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !place.subtitle.isEmpty {
                        Text(place.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            case .directory(let directory):
                VStack(alignment: .leading, spacing: 1) {
                    Text(directory.leaf)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(directory.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
    }
}
