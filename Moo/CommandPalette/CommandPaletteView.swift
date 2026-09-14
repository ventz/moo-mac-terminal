//
//  CommandPaletteView.swift
//  Moo
//
//  The command-K overlay. Return runs a command or copies a match,
//  command-Return opens a match, Escape or a click outside closes. Arrow,
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
            TextField("Search commands and what is on screen", text: Bindable(model).query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .focused($searchIsFocused)
                // A pass later: focus set before the field exists is dropped.
                .onAppear {
                    Task { @MainActor in searchIsFocused = true }
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
                                row(item, isSelected: index == model.selection)
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
            Text("↩ run or copy  ·  ⌘↩ open  ·  esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 18)
    }

    @ViewBuilder
    private func row(_ item: CommandPaletteModel.Item, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case .match(let match):
                Text(match.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    private func open() {
        let rows = controller?.terminal?.terminalStateSnapshot().visibleRows.map(\.text) ?? []
        let workspaces = projects.map { project in
            PaletteCommand(
                id: "workspace:\(project.id.uuidString)",
                title: project.name,
                path: "Switch to Workspace",
                shortcut: ""
            ) { [scope] in
                ProjectRuntime.shared.select(projectID: project.id, in: scope)
            }
        }
        model = CommandPaletteModel(
            matches: QuickSelectMatcher.matches(inRows: rows),
            commands: workspaces + MenuCommandCollector.commands(in: NSApp.mainMenu)
        )
        installKeyMonitor()
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
                perform(item, opening: event.modifierFlags.contains(.command))
            }
            return nil
        default:
            return event
        }
    }

    private func perform(_ item: CommandPaletteModel.Item, opening: Bool) {
        close()
        switch item {
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
