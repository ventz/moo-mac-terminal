//
//  TerminalWindowAppearance.swift
//  Moo
//

import AppKit

@MainActor
enum TerminalWindowAppearance {
    private static let themeBackgrounds = NSMapTable<NSWindow, NSColor>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    /// Windows with a refresh already queued for the next turn of the main
    /// queue. Every pane of a split observes the same window, so without this
    /// an N-pane window would walk the titlebar tree N times per activation.
    private static let pendingRefreshes = NSHashTable<NSWindow>.weakObjects()
    /// Windows whose chrome already shows the stored state. A window is absent
    /// while its titlebar is out of reach (it is not built yet, or the window
    /// is in full screen), which keeps the next update from being skipped.
    private static let settledWindows = NSHashTable<NSWindow>.weakObjects()
    /// Windows whose profile asks for the standard title bar (Appearance →
    /// Title bar), drawn in the system's appearance rather than the theme's.
    private static let standardTitlebarWindows = NSHashTable<NSWindow>.weakObjects()
    /// Follows the system's light/dark switch while any window has a standard
    /// title row. The window itself is pinned to the theme's appearance, so
    /// nothing else tells its titlebar the system changed.
    private static var systemAppearanceObservation: NSKeyValueObservation?

    static func apply(
        theme: TerminalTheme?,
        backgroundOpacity: Double = 1,
        usesStandardTitlebar: Bool = false,
        to window: NSWindow
    ) {
        let color = theme.map { theme -> NSColor in
            let background = theme.background
            return NSColor(
                srgbRed: CGFloat(background.red) / 65_535,
                green: CGFloat(background.green) / 65_535,
                blue: CGFloat(background.blue) / 65_535,
                // The titlebar is folded into the translucent content region,
                // so an opaque band over a translucent terminal would not match.
                alpha: CGFloat(backgroundOpacity)
            )
        }
        // SwiftUI reapplies this on every update of the terminal view; a
        // repeated refresh would relayout the whole titlebar for nothing.
        guard color != themeBackgrounds.object(forKey: window)
                || usesStandardTitlebar != standardTitlebarWindows.contains(window)
                || !settledWindows.contains(window)
        else { return }

        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
        }
        if let color {
            themeBackgrounds.setObject(color, forKey: window)
        } else {
            themeBackgrounds.removeObject(forKey: window)
        }
        if usesStandardTitlebar {
            standardTitlebarWindows.add(window)
            observeSystemAppearance()
        } else {
            standardTitlebarWindows.remove(window)
        }
        scheduleChromeRefresh(for: window)
    }

    /// The light or dark appearance System Settings asks for. Moo never sets
    /// `NSApp.appearance`, so the app's effective appearance is the system's.
    static func systemAppearance(_ effective: NSAppearance? = nil) -> NSAppearance? {
        let effective = effective ?? NSApp.effectiveAppearance
        // Increase Contrast is not lost here: AppKit applies it system-wide,
        // and even NSAppearance(named: .accessibilityHighContrastAqua) comes
        // back named plain .aqua (checked on macOS 26, 2026-10-03).
        let name = effective.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return NSAppearance(named: name)
    }

    /// What a standard title row is painted with: the system window color in
    /// the system appearance (white in light mode, as in Terminal.app), and
    /// always opaque, so it stands apart from a translucent terminal.
    ///
    /// Painted rather than left to AppKit: on macOS 26 the native titlebar
    /// background is see-through, so with only the appearance changed the
    /// title turned dark while the dark terminal still showed behind it.
    static func standardTitlebarColor(in appearance: NSAppearance?) -> NSColor {
        var color = NSColor.windowBackgroundColor
        (appearance ?? NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color.withAlphaComponent(1)
    }

    private static func observeSystemAppearance() {
        guard systemAppearanceObservation == nil else { return }
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                for window in standardTitlebarWindows.allObjects {
                    settledWindows.remove(window)
                    scheduleChromeRefresh(for: window)
                }
            }
        }
    }

    static func scheduleChromeRefresh(for window: NSWindow) {
        guard !pendingRefreshes.contains(window) else { return }
        pendingRefreshes.add(window)
        // AppKit moves and reuses the native tab bar while selecting a tab.
        // Refresh on the next turn, after that view hierarchy has settled.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            pendingRefreshes.remove(window)
            window.toolbar?.validateVisibleItems()
            guard let frameView = window.contentView?.superview,
                  let chromeView = firstDescendant(named: "NSTitlebarContainerView", in: frameView)
            else {
                // In full screen AppKit hosts the titlebar in a separate
                // window. There is no chrome to color here; a later refresh
                // reapplies the current state when it comes back.
                settledWindows.remove(window)
                return
            }
            let standard = standardTitlebarWindows.contains(window)
            // The window keeps the theme's appearance for everything below
            // the title row; only the titlebar container follows the system.
            let titlebarAppearance = standard ? systemAppearance() : nil
            chromeView.appearance = titlebarAppearance
            let settled = applyBackground(
                standard
                    ? standardTitlebarColor(in: titlebarAppearance)
                    : themeBackgrounds.object(forKey: window),
                to: chromeView
            )
            if settled {
                settledWindows.add(window)
            } else {
                settledWindows.remove(window)
            }
            invalidate(chromeView)
            chromeView.layoutSubtreeIfNeeded()
            chromeView.displayIfNeeded()
        }
    }

    /// Colors AppKit's native titlebar instead of placing a SwiftUI toolbar
    /// background over it. This preserves the native, full-height drag region
    /// and follows Ghostty's MIT-licensed transparent-titlebar implementation:
    /// https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Terminal/Window%20Styles/TransparentTitlebarTerminalWindow.swift
    /// Returns whether the chrome now shows `color`.
    @discardableResult
    private static func applyBackground(_ color: NSColor?, to chromeView: NSView) -> Bool {
        if #available(macOS 26.0, *) {
            let backgroundView = firstDescendant(named: "NSTitlebarBackgroundView", in: chromeView)
            let titlebarView = firstDescendant(named: "NSTitlebarView", in: chromeView)
            titlebarView?.wantsLayer = color != nil
            titlebarView?.layer?.backgroundColor = color?.cgColor
            // Hide the native background only once the themed layer replaces
            // it, and always restore it when the theme is removed.
            backgroundView?.isHidden = color != nil && titlebarView != nil
            return titlebarView != nil
        } else {
            chromeView.wantsLayer = color != nil
            chromeView.layer?.backgroundColor = color?.cgColor
            chromeView.window?.titlebarAppearsTransparent = color != nil
            return true
        }
    }

    private static func invalidate(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        view.subviews.forEach(invalidate)
    }

    private static func firstDescendant(named className: String, in view: NSView) -> NSView? {
        if view.className == className {
            return view
        }
        for subview in view.subviews {
            if let match = firstDescendant(named: className, in: subview) {
                return match
            }
        }
        return nil
    }
}
