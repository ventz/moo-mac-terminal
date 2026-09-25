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

    private struct PendingMarks: Sendable {
        var events: [TerminalOscEvent] = []
        var hopScheduled = false
    }

    /// Command marks waiting for the main thread. Output can print them by
    /// the thousand (`cat` a file of `\e]133;C\a`), so at most one hop is
    /// queued and only the newest few survive it.
    static let markBurstLimit = 64

    private let handler = LockedMainActorCallback<Event>()
    private let lastOutputNotification = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let pendingMarks = OSAllocatedUnfairLock(initialState: PendingMarks())

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
        if event.code == CommandTracker.oscCode {
            sendCommandMark(event)
            return
        }
        guard TerminalNotificationParser.observedCodes.contains(event.code),
              let handler = handler.current else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(.osc(event))
            }
        }
    }

    nonisolated private func sendCommandMark(_ event: TerminalOscEvent) {
        guard event.payload.count <= CommandTracker.payloadLimit,
              let handler = handler.current else { return }
        let schedulesHop = pendingMarks.withLock { state -> Bool in
            if state.events.count >= Self.markBurstLimit {
                state.events.removeFirst()
            }
            state.events.append(event)
            guard !state.hopScheduled else { return false }
            state.hopScheduled = true
            return true
        }
        guard schedulesHop else { return }
        DispatchQueue.main.async { [pendingMarks] in
            let events = pendingMarks.withLock { state -> [TerminalOscEvent] in
                let events = state.events
                state.events.removeAll(keepingCapacity: true)
                state.hopScheduled = false
                return events
            }
            MainActor.assumeIsolated {
                for event in events {
                    handler(.osc(event))
                }
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

    // MARK: OSC 52 clipboard
    //
    // SwiftTerm's defaults answer an OSC 52 read with the entire clipboard and
    // apply an OSC 52 write unconditionally. That puts the clipboard under the
    // control of whatever is running in the pane: `cat` a crafted file, or
    // read anything a remote host prints over ssh, and `ESC ] 52 ; c ; ? BEL`
    // sends the clipboard back — frequently a password just pasted from a
    // password manager — with no user action and nothing on screen.
    //
    // The kitty clipboard protocol already asks first (see
    // TerminalSessionController.kittyClipboardRequestPermission). This makes
    // the xterm path agree with it.

    /// Refused, always. There is no use for a program reading the clipboard
    /// that justifies handing it to a remote host silently, and reads are the
    /// half of OSC 52 that exfiltrates.
    override func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    /// Allowed with consent. A write is genuinely useful — yanking from vim on
    /// a remote machine into the local clipboard — so it is asked about rather
    /// than refused, with the text shown before it lands.
    override func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else {
            return
        }
        guard sessionController?.permitsClipboardWrite(text) == true else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
        resumeWhenReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resumeWhenReady()
    }

    /// A shell start or focus request may be waiting for this view to have a
    /// window or a usable size. Deferred a turn so it never runs inside
    /// AppKit's own layout pass: starting the shell lays the view out, and
    /// doing that from within setFrameSize would re-enter layout.
    private func resumeWhenReady() {
        guard sessionController?.isWaitingForTerminal == true else { return }
        DispatchQueue.main.async { [weak self] in
            self?.sessionController?.terminalViewBecameReady()
        }
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
    ///
    /// A control-click opens the context menu instead, as it does in Ghostty
    /// and Terminal, for a mouse or trackpad without a secondary click.
    override func mouseDown(with event: NSEvent) {
        focusForClick()
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    /// A right-click focuses the pane under it, as a left click does, so the
    /// menu it opens and the keystrokes after it act on the same pane.
    /// SwiftTerm does not report right clicks to programs, so nothing running
    /// in the pane loses the click to the menu.
    override func rightMouseDown(with event: NSEvent) {
        focusForClick()
        super.rightMouseDown(with: event)
    }

    /// Opened by a right-click or a control-click. A control-click is left to
    /// the program while it tracks the mouse (vim with `mouse=a`, tmux), as
    /// Ghostty does; right clicks are never reported, so they always open it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let programTracksMouse = allowMouseReporting && currentMouseMode != .off
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)
                && !programTracksMouse)
        guard isContextClick, let sessionController else { return nil }
        return TerminalContextMenu.make(for: sessionController)
    }

    private func focusForClick() {
        if window?.firstResponder !== self,
           window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
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

    // MARK: Command-hover underline for bare file names

    /// SwiftTerm underlines what it detects while Command is held, but a bare
    /// `README.md` is only found by `mouseUp` after the click. This draws the
    /// same cue for it. SwiftTerm's `mouseMoved`/`flagsChanged` are public,
    /// not open, so a local monitor watches instead.
    private let fileLinkUnderline = FileLinkUnderlineView()
    private var hoverMonitor: Any?
    private var hoverCache: (key: String, isFile: Bool)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
            hoverMonitor = nil
            hideFileLinkUnderline()
            return
        }
        guard hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .mouseMoved, .leftMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateFileLinkUnderline(for: event)
            }
            return event
        }
    }

    private func updateFileLinkUnderline(for event: NSEvent) {
        guard event.type == .flagsChanged || event.type == .mouseMoved,
              let window, event.window === window,
              window.isKeyWindow,
              event.modifierFlags.contains(.command),
              let span = fileSpanUnderPointer()
        else {
            hideFileLinkUnderline()
            return
        }
        if fileLinkUnderline.superview !== self {
            addSubview(fileLinkUnderline)
        }
        fileLinkUnderline.color = nativeForegroundColor
        let lineHeight = max(1, span.cell.height * 0.08)
        fileLinkUnderline.frame = CGRect(
            x: CGFloat(span.columns.lowerBound) * span.cell.width,
            y: frame.height - CGFloat(span.row + 1) * span.cell.height + span.cell.height * 0.12,
            width: CGFloat(span.columns.count) * span.cell.width,
            height: lineHeight
        )
    }

    private func hideFileLinkUnderline() {
        if fileLinkUnderline.superview != nil {
            fileLinkUnderline.removeFromSuperview()
        }
    }

    /// The existing file under the pointer, as the click would open it.
    /// Paths with a slash are skipped: SwiftTerm already underlines those.
    private func fileSpanUnderPointer() -> (row: Int, columns: Range<Int>, cell: CGSize)? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return nil }
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
        let column = Int(point.x / cell.width)
        let row = Int((frame.height - point.y) / cell.height)
        guard let line = snapshot.visibleRows.first(where: { $0.row == row }) else { return nil }
        let cells = LinkRouter.cells(fromRowText: line.text, cellWidths: line.cellWidths)
        guard let span = LinkRouter.wordSpan(inCells: cells, at: column),
              !span.word.contains("/")
        else { return nil }
        let directory = sessionController?.currentWorkingDirectory
        let key = "\(directory ?? "")\u{0}\(span.word)"
        let isFile: Bool
        if let hoverCache, hoverCache.key == key {
            isFile = hoverCache.isFile
        } else {
            isFile = LinkRouter.resolvePath(span.word, workingDirectory: directory) != nil
            hoverCache = (key, isFile)
        }
        return isFile ? (row, span.columns, cell) : nil
    }

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

/// A thin line under a bare file name while Command is held.
private final class FileLinkUnderlineView: NSView {
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
