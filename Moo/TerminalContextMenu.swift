//
//  TerminalContextMenu.swift
//  Moo
//

import AppKit
import SwiftTerm

/// The menu a right-click on a terminal pane opens: the pane, theme, buffer,
/// reset and font commands from the Terminal menu, acting on the pane that was
/// clicked rather than whichever one last had focus.
///
/// Built fresh for each click so titles and enabled states match the pane at
/// that moment, the way the Terminal menu's do.
@MainActor
enum TerminalContextMenu {
    static func make(
        for controller: TerminalSessionController,
        runtime: ProjectRuntime = .shared
    ) -> NSMenu {
        let paneCount = controller.workspace?.paneCount ?? 1
        let isZoomed = controller.workspace?.isZoomed == true
        // Same rule as the Terminal menu: the last pane of a workspace tab
        // closes the tab.
        let closesTab = paneCount <= 1 && runtime.scope(showing: controller) != nil

        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.items = [
            Item("Split Pane", key: "d") { [weak controller] in
                guard let controller else { return }
                controller.workspace?.split(controller, orientation: .vertical)
            },
            Item("Split Pane Horizontally", key: "d", modifiers: [.command, .shift]) { [weak controller] in
                guard let controller else { return }
                controller.workspace?.split(controller, orientation: .horizontal)
            },
            Item(isZoomed ? "Unzoom Pane" : "Zoom Pane", key: "\r", modifiers: [.command, .shift],
                 isEnabled: paneCount > 1) { [weak controller] in
                controller?.workspace?.toggleZoom()
            },
            Item(closesTab ? "Close Tab" : "Close Pane", key: "w") { [weak controller] in
                controller?.requestClose()
            },
            .separator(),
            Item("Theme…") { [weak controller] in
                controller?.showThemePicker = true
            },
            .separator(),
            Item("Export Buffer...") { [weak controller] in
                controller?.exportBuffer()
            },
            Item("Clear Scrollback", key: "k", modifiers: [.command, .option]) { [weak controller] in
                controller?.terminal?.clearScrollback()
            },
            .separator(),
            Item("Scroll to Previous Prompt", key: arrow(NSUpArrowFunctionKey)) { [weak controller] in
                controller?.scrollToPreviousPrompt()
            },
            Item("Scroll to Next Prompt", key: arrow(NSDownArrowFunctionKey)) { [weak controller] in
                controller?.scrollToNextPrompt()
            },
            Item("Soft Reset") { [weak controller] in
                controller?.softReset()
            },
            Item("Hard Reset") { [weak controller] in
                controller?.hardReset()
            },
            .separator(),
            Item("Bigger Font", key: "+") { [weak controller] in
                controller?.biggerFont()
            },
            Item("Smaller Font", key: "-") { [weak controller] in
                controller?.smallerFont()
            },
            Item("Default Font Size", key: "0") { [weak controller] in
                controller?.defaultFontSize()
            },
        ]
        return menu
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }

    /// A menu item that runs a closure. It is its own target, and the menu
    /// holding it keeps it alive for as long as the menu is open.
    final class Item: NSMenuItem {
        private let handler: () -> Void

        init(
            _ title: String,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = [.command],
            isEnabled: Bool = true,
            handler: @escaping () -> Void
        ) {
            self.handler = handler
            super.init(title: title, action: #selector(fire(_:)), keyEquivalent: key)
            target = self
            keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            self.isEnabled = isEnabled
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        @objc func fire(_ sender: Any?) {
            handler()
        }
    }
}
