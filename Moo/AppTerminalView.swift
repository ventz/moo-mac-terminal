//
//  AppTerminalView.swift
//  Moo
//

import AppKit
import Foundation
import os
import SwiftTerm

/// Stores a main-actor callback behind a stable object reference.
///
/// Do not store the function directly in the generic lock. A generic `inout`
/// read can write a new reabstraction thunk back to the stored function. Each
/// read can then add a thunk and create an unbounded call and release chain.
nonisolated final class LockedMainActorCallback<Input: Sendable>: Sendable {
    private final class Callback: Sendable {
        let body: @MainActor @Sendable (Input) -> Void

        init(_ body: @escaping @MainActor @Sendable (Input) -> Void) {
            self.body = body
        }
    }

    private let callback = OSAllocatedUnfairLock<Callback?>(initialState: nil)

    func replace(with body: (@MainActor @Sendable (Input) -> Void)?) {
        let next = body.map(Callback.init)
        callback.withLock { $0 = next }
    }

    var current: (@MainActor @Sendable (Input) -> Void)? {
        callback.withLock { $0 }?.body
    }
}

private final class TerminalSessionEventDelivery: Sendable {
    private enum Event: Sendable {
        case bell
        case output
        case osc(TerminalOscEvent)
    }

    private let handler = LockedMainActorCallback<Event>()
    private let lastOutputNotification = OSAllocatedUnfairLock(initialState: Date.distantPast)

    @MainActor
    func setController(_ controller: TerminalSessionController?) {
        handler.replace { [weak controller] event in
            switch event {
            case .bell:
                controller?.noteBell()
            case .output:
                controller?.noteOutputActivity()
            case .osc(let event):
                controller?.noteOscEvent(event)
            }
        }
    }

    /// OSC events arrive on SwiftTerm's observer queue. The main queue, not a
    /// Task, carries them across: kitty splits one notification over several
    /// sequences, and only a serial queue keeps those in order.
    nonisolated func sendOsc(_ event: TerminalOscEvent) {
        guard TerminalNotificationParser.observedCodes.contains(event.code),
              let handler = handler.current else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(.osc(event))
            }
        }
    }

    nonisolated func sendBell() {
        guard let handler = handler.current else { return }
        Task { @MainActor in
            handler(.bell)
        }
    }

    nonisolated func sendOutput() {
        let shouldNotify = lastOutputNotification.withLock { lastNotification in
            let now = Date()
            guard now.timeIntervalSince(lastNotification) > 0.25 else { return false }
            lastNotification = now
            return true
        }
        guard shouldNotify, let handler = handler.current else { return }
        Task { @MainActor in
            handler(.output)
        }
    }
}

final class AppTerminalView: LocalProcessTerminalView {
    weak var sessionController: TerminalSessionController? {
        didSet {
            eventDelivery.setController(sessionController)
            setProcessOutputHandler { [eventDelivery] in
                eventDelivery.sendOutput()
            }
            observeNotificationsIfNeeded()
        }
    }

    nonisolated private let eventDelivery = TerminalSessionEventDelivery()
    private var oscObservation: TerminalOscObservation?
    var fileDropShellResolver = TerminalShellResolver()

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sessionController?.noteInputActivity()
        super.send(source: source, data: data)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              TerminalFileDrop.hasFileURLs(in: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingEntered(sender) == .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return insertDroppedFiles(from: sender.draggingPasteboard)
    }

    @discardableResult
    func insertDroppedFiles(from pasteboard: NSPasteboard) -> Bool {
        guard TerminalFileDrop.hasFileURLs(in: pasteboard) else { return false }
        let dialect = fileDropShellResolver.dialect(for: process?.childfd)
        guard let text = TerminalFileDrop.text(from: pasteboard, dialect: dialect) else { return false }
        if window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
        // Paste semantics let applications recognize dropped image paths and
        // apply bracketed-paste framing when the application has enabled it.
        pasteText(text)
        return true
    }

    /// A click in an unfocused split moves focus there. SwiftTerm does not take
    /// first responder on its own, so without this the keystrokes after the
    /// click still go to the pane that had focus.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self,
           window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
        super.mouseDown(with: event)
    }

    /// Watches for the escape sequences programs use to ask for the user.
    /// Observed rather than overridden, so SwiftTerm's own handling of those
    /// codes — the OSC 9;4 progress bar — is untouched.
    private func observeNotificationsIfNeeded() {
        guard oscObservation == nil, sessionController != nil else { return }
        oscObservation = observeOscEvents { [eventDelivery] event in
            eventDelivery.sendOsc(event)
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.vpetkov.Moo",
        category: "Links"
    )

    private var didOpenLinkDuringClick = false

    /// A click on a link or a detected path. Routed through LinkRouter so a
    /// markdown file or a web address can open as a tab in this workspace;
    /// anything else, or an option-click, opens with the system as before.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        didOpenLinkDuringClick = true
        LinkRouter.open(link, from: sessionController)
    }

    /// A command-click SwiftTerm found no link under still opens the word
    /// beneath it when that word names an existing file in the terminal's
    /// directory — the bare `README.md` in `ls` output.
    override func mouseUp(with event: NSEvent) {
        didOpenLinkDuringClick = false
        super.mouseUp(with: event)
        guard event.modifierFlags.contains(.command),
              event.clickCount == 1,
              !didOpenLinkDuringClick,
              !selectionActive
        else { return }
        guard let word = word(under: event) else {
            Self.logger.debug("command-click: no word under the pointer")
            return
        }
        let directory = sessionController?.currentWorkingDirectory
        guard LinkRouter.resolvePath(word, workingDirectory: directory) != nil else {
            Self.logger.debug(
                "command-click: \(word, privacy: .private) is not a file in \(directory ?? "<no OSC 7 directory>", privacy: .private)"
            )
            return
        }
        LinkRouter.open(word, from: sessionController)
    }

    /// Mirrors SwiftTerm's own hit test against the rows it copies out under
    /// its lock. The caret view is sized to exactly one cell; without one,
    /// the view divided by the grid is within a fraction of a cell.
    private func word(under event: NSEvent) -> String? {
        let snapshot = terminalStateSnapshot()
        let dimensions = snapshot.dimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        var cell = caretFrame.size
        if cell.width <= 0 || cell.height <= 0 {
            cell = CGSize(
                width: bounds.width / CGFloat(dimensions.cols),
                height: bounds.height / CGFloat(dimensions.rows)
            )
        }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / cell.width)
        let row = Int((frame.height - point.y) / cell.height)
        guard let line = snapshot.visibleRows.first(where: { $0.row == row }) else { return nil }
        let cells = LinkRouter.cells(fromRowText: line.text, cellWidths: line.cellWidths)
        return LinkRouter.word(inCells: cells, at: column)
    }

    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        eventDelivery.sendBell()
    }

    /// Uses the current terminal-driver control bytes when SwiftTerm filters
    /// text before it sends a paste to the PTY.
    nonisolated override func terminalControlBytesForPaste(source: Terminal) -> Set<UInt8> {
        process?.terminalControlBytesForPaste()
            ?? TerminalPasteControls.approximateTerminalControlBytes
    }
}
