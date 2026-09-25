import AppKit
import Testing
@testable import Moo

@MainActor
final class TerminalContextMenuTests {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    @Test func listsThePaneCommandsInTerminalMenuOrder() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let menu = TerminalContextMenu.make(for: workspace.controllers[0])
        #expect(titles(menu) == [
            "Split Pane", "Split Pane Horizontally", "Zoom Pane", "Close Pane",
            "-",
            "Theme…",
            "-",
            "Export Buffer...", "Clear Scrollback",
            "-",
            "Scroll to Previous Prompt", "Scroll to Next Prompt", "Soft Reset", "Hard Reset",
            "-",
            "Bigger Font", "Smaller Font", "Default Font Size",
        ])
    }

    @Test func showsTheTerminalMenuShortcuts() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let menu = TerminalContextMenu.make(for: workspace.controllers[0])
        let split = item("Split Pane Horizontally", in: menu)
        #expect(split?.keyEquivalent == "d")
        #expect(split?.keyEquivalentModifierMask == [.command, .shift])
        #expect(item("Clear Scrollback", in: menu)?.keyEquivalentModifierMask == [.command, .option])
        let soft = item("Soft Reset", in: menu)
        #expect(soft?.keyEquivalent == "")
        #expect(soft?.keyEquivalentModifierMask == [])
    }

    @Test func zoomNeedsASecondPane() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = workspace.controllers[0]
        #expect(item("Zoom Pane", in: TerminalContextMenu.make(for: first))?.isEnabled == false)

        workspace.split(first, orientation: .vertical)
        #expect(item("Zoom Pane", in: TerminalContextMenu.make(for: first))?.isEnabled == true)

        workspace.toggleZoom()
        #expect(item("Unzoom Pane", in: TerminalContextMenu.make(for: first)) != nil)
    }

    @Test func splitActsOnTheClickedPane() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = workspace.controllers[0]
        workspace.split(first, orientation: .vertical)
        let second = workspace.controllers[1]
        workspace.markFocused(second)

        let menu = TerminalContextMenu.make(for: first)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Split Pane Horizontally"))

        #expect(workspace.paneCount == 3)
        // The new pane lands beside the pane that was clicked, not the one
        // that had focus.
        guard case .split(.vertical, let left, _) = workspace.root.content,
              case .split(.horizontal, _, _) = left.content else {
            Issue.record("the clicked pane should have been split")
            return
        }
    }

    @Test func themeOpensThePickerForThatPane() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let controller = workspace.controllers[0]
        let menu = TerminalContextMenu.make(for: controller)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Theme…"))
        #expect(controller.showThemePicker)
    }

    private func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    @Test func rightClickAndControlClickOpenTheMenu() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let controller = workspace.controllers[0]
        let view = AppTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.sessionController = controller

        #expect(view.menu(for: click(.rightMouseDown))?.items.first?.title == "Split Pane")
        #expect(view.menu(for: click(.leftMouseDown, modifiers: .control))?.items.first?.title == "Split Pane")
        #expect(view.menu(for: click(.leftMouseDown)) == nil)
        #expect(view.menu(for: click(.leftMouseDown, modifiers: .command)) == nil)
        withExtendedLifetime(controller) {}
    }
}
