//
//  WindowTitleAccessory.swift
//  Moo
//
//  Shows the window title as a plain label instead of AppKit's own.
//
//  Moo's windows come from SwiftUI's DocumentGroup, and AppKit makes a
//  document window's title a control: clicking it opens a rename/move
//  popover ("ventz.moo", Where: Documents) with a chevron beside the title.
//  For a terminal that offers to file the window away as a document, which
//  only confuses. There is no public switch for it, and turning off the
//  document's autosave would change how saved .moo sessions close, so the
//  system title is hidden and this label shows the same text.
//
//  The label is not a control: clicks fall through to the titlebar, so the
//  title area still drags the window and double-click still zooms it.
//

import AppKit

final class WindowTitleAccessory: NSTitlebarAccessoryViewController {
    /// Room for the traffic lights before the title, and for the update dot
    /// after it.
    static let leadingInset: CGFloat = 78
    static let trailingReserve: CGFloat = 44

    private let label = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    /// Adds the label once and hides the system title; SwiftUI configures a
    /// window many times.
    static func install(in window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0 is WindowTitleAccessory })
        else { return }
        window.titleVisibility = .hidden
        let accessory = WindowTitleAccessory()
        window.addTitlebarAccessoryViewController(accessory)
        accessory.track(window)
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
        let container = TitleContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        container.clipsToBounds = true
        container.setAccessibilityElement(false)
        label.font = .titleBarFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        // One line, always. The title is sanitized where it is composed
        // (TerminalTitleComposer.displayable), and this keeps anything that
        // slips past from drawing a second line over the terminal.
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        // VoiceOver already reads the window's own title; the label would
        // repeat it.
        label.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        // Centered on the window, as AppKit and Terminal.app center it; the
        // centering gives way first, so a long title slides over rather than
        // running under the traffic lights or the update dot.
        let centering = label.centerXAnchor.constraint(equalTo: container.leadingAnchor)
        centering.priority = .defaultHigh
        container.centering = centering
        NSLayoutConstraint.activate([
            centering,
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func track(_ window: NSWindow) {
        observations = [
            // KVO calls back on the thread that set the title. Every setter
            // is on main today, but a crash is too high a price if one ever
            // is not, so hop rather than assume.
            window.observe(\.title, options: [.initial]) { [weak self] window, _ in
                // Cleaned again here, not only where Moo composes the title:
                // AppKit and NSDocument set titles too, and a single-line
                // label still sizes itself for an embedded newline.
                let title = TerminalTitleComposer.displayable(window.title)
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.label.stringValue = title }
                } else {
                    DispatchQueue.main.async { self?.label.stringValue = title }
                }
            }
        ]
        let center = NotificationCenter.default
        let mainChanged: (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.updateColor(for: window)
            }
        }
        let resized: (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.updateWidth(for: window)
            }
        }
        notificationTokens = [
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main, using: mainChanged),
            center.addObserver(forName: NSWindow.didResignMainNotification, object: window, queue: .main, using: mainChanged),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: resized)
        ]
        updateColor(for: window)
        updateWidth(for: window)
    }

    /// Dimmed when the window is in the background, as AppKit's own title is.
    private func updateColor(for window: NSWindow) {
        let color: NSColor = window.isMainWindow ? .labelColor : .tertiaryLabelColor
        if label.textColor != color {
            label.textColor = color
        }
    }

    /// Runs on every frame of a live resize, so it only touches the frame
    /// when the width actually changed.
    private func updateWidth(for window: NSWindow) {
        let width = max(0, window.frame.width - Self.leadingInset - Self.trailingReserve)
        if view.frame.width != width {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
    }

    /// Lets a click or drag on the title move the window, as the system
    /// title does.
    final class TitleContainerView: NSView {
        /// Puts the label's center at the window's center, measured from
        /// where AppKit actually placed this accessory.
        var centering: NSLayoutConstraint?

        override var mouseDownCanMoveWindow: Bool { true }

        override func layout() {
            if let window, let centering {
                let origin = convert(NSPoint.zero, to: nil).x
                let target = window.frame.width / 2 - origin
                if centering.constant != target {
                    centering.constant = target
                }
            }
            super.layout()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
