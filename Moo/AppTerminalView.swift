//
//  AppTerminalView.swift
//  Moo
//

import AppKit
import Foundation
import os
import SwiftTerm

private final class TerminalSessionEventDelivery: Sendable {
    private enum Event: Sendable {
        case bell
        case output
    }

    private let handler = OSAllocatedUnfairLock<(@MainActor @Sendable (Event) -> Void)?>(
        initialState: nil)
    private let lastOutputNotification = OSAllocatedUnfairLock(initialState: Date.distantPast)

    @MainActor
    func setController(_ controller: TerminalSessionController?) {
        handler.withLock { storedHandler in
            storedHandler = { [weak controller] event in
                switch event {
                case .bell:
                    controller?.noteBell()
                case .output:
                    controller?.noteOutputActivity()
                }
            }
        }
    }

    nonisolated func sendBell() {
        guard let handler = handler.withLock({ $0 }) else { return }
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
        guard shouldNotify, let handler = handler.withLock({ $0 }) else { return }
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
        }
    }

    nonisolated private let eventDelivery = TerminalSessionEventDelivery()

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
