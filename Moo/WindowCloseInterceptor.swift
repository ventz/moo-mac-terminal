//
//  WindowCloseInterceptor.swift
//  Moo
//
//  NSDocument and SwiftUI both manage NSWindow delegates. This forwarding
//  proxy is deliberately narrow and fragile: re-install it when its window
//  becomes key, and forward all behavior other than closing to the delegate
//  that was already installed.
//

import AppKit
import Darwin
import SwiftTerm

@MainActor
enum TerminalClosePolicy {
    static func requiresConfirmation(for controller: TerminalSessionController) -> Bool {
        guard let process = controller.terminal?.process, process.running else {
            return false
        }

        switch controller.profile.askBeforeClosing {
        case .never:
            return false
        case .always:
            return true
        case .onlyIfProcessesRunning:
            return childProcessCount(parentPID: process.shellPid) > 0
        }
    }

    nonisolated private static func childProcessCount(parentPID: pid_t) -> Int {
        guard parentPID > 0 else { return 0 }
        var childPIDs = [pid_t](repeating: 0, count: 256)
        let count = childPIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(parentPID,
                               buffer.baseAddress,
                               Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        return max(0, Int(count))
    }
}

/// What the window-close confirmation says will end.
enum WindowClosePrompt {
    static func message(endingTabs tabs: Int, projects: Int, processRunning: Bool) -> String {
        var message: String
        if projects > 1 {
            message = "This is the last window, so the shells in all \(projects) projects will be ended."
        } else if tabs > 1 {
            message = "Its \(tabs) tabs will be closed and their shells ended."
        } else {
            message = "Its shell will be ended."
        }
        if processRunning {
            message += " A process is still running."
        }
        return message
    }
}

@MainActor
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var forwardedDelegate: (any NSWindowDelegate)?
    private var observers: [NSObjectProtocol] = []
    private var bypassClose = false
    private var isPresentingConfirmation = false
    /// Some AppKit delegate proxies implement `responds(to:)` by asking the
    /// window's current delegate. After this interceptor is installed, that
    /// query comes back here. Stop that cycle before it exhausts the stack.
    private var isQueryingForwardedDelegate = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        install()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.install()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// AppKit can replace this window's delegate during document restoration.
    /// Preserve that delegate and put this proxy back in front of it.
    func install() {
        guard let window, window.delegate !== self else { return }
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    func uninstall() {
        guard let window, window.delegate === self else { return }
        window.delegate = forwardedDelegate
        forwardedDelegate = nil
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwardedDelegateResponds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(windowShouldClose(_:)) {
            return nil
        }
        guard forwardedDelegateResponds(to: aSelector) else { return nil }
        return forwardedDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for controller in TerminalSessionRegistry.shared.controllers(for: sender) {
            controller.flushBufferSnapshot()
        }

        if bypassClose {
            return forwardedWindowShouldClose(sender)
        }

        // cmd+W and the red button both arrive here, and they mean different
        // things. cmd+W closes the thing you are working in: with workspace
        // tabs that is a tab, or a project, never the whole window at once.
        // The red button belongs to one particular window and means that
        // window — so it skips the tab/project policy and goes straight to the
        // window confirmation below. Routing it through the policy used to act
        // on the key window rather than this one, and with the sidebar showing
        // it could delete a project when all that was asked was to close a
        // window.
        if !Self.isCloseButtonClick(NSApp.currentEvent, in: sender),
           ProjectCloseCoordinator.closeSelected(
               in: ProjectRuntime.shared.scope(for: sender)
           ) == .handled {
            return false
        }

        // Closing the window ends every shell it holds — no session is kept
        // alive without a window to reach it from — so always ask first.
        let ended = ProjectRuntime.shared.sessionsEnded(byClosing: sender)
        let controllers = TerminalSessionRegistry.shared.controllers(for: sender)
        guard !ended.isEmpty || !controllers.isEmpty else {
            return forwardedWindowShouldClose(sender)
        }

        guard !isPresentingConfirmation else { return false }
        isPresentingConfirmation = true

        let alert = NSAlert()
        alert.messageText = ended.count > 1 ? "Close the last window?" : "Close this window?"
        alert.informativeText = WindowClosePrompt.message(
            endingTabs: ended.reduce(0) { $0 + $1.tabs.count },
            projects: ended.count,
            processRunning: (ended.flatMap(\.controllers) + controllers)
                .contains(where: TerminalClosePolicy.requiresConfirmation)
        )
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.isPresentingConfirmation = false
            guard response == .alertFirstButtonReturn else { return }
            self.bypassClose = true
            sender?.close()
        }
        return false
    }

    /// Whether `event` is a click on `window`'s own close button, as opposed
    /// to cmd+W or File ▸ Close (a key event, or a click in a menu).
    ///
    /// Tested by position rather than by event type alone: choosing File ▸ Close
    /// with the mouse is also a mouse event, but it happens in the menu, not on
    /// this window's button, and it should behave like cmd+W.
    static func isCloseButtonClick(_ event: NSEvent?, in window: NSWindow) -> Bool {
        guard let event,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              event.window === window,
              let button = window.standardWindowButton(.closeButton),
              let container = button.superview else {
            return false
        }
        let point = container.convert(event.locationInWindow, from: nil)
        return button.frame.contains(point)
    }

    private func forwardedDelegateResponds(to selector: Selector) -> Bool {
        guard !isQueryingForwardedDelegate,
              let forwardedDelegate,
              forwardedDelegate !== self else {
            return false
        }
        isQueryingForwardedDelegate = true
        defer { isQueryingForwardedDelegate = false }
        return forwardedDelegate.responds(to: selector)
    }

    private func forwardedWindowShouldClose(_ sender: NSWindow) -> Bool {
        let selector = #selector(NSWindowDelegate.windowShouldClose(_:))
        guard forwardedDelegateResponds(to: selector) else { return true }
        return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }
}
