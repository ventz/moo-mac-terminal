//
//  WindowChromeOpacity.swift
//  Moo
//

import AppKit
import Observation

enum WindowChromeDefaults {
    /// App-wide: pin the tab strip opaque in every window, whatever the
    /// profile says. A profile can still pin it on its own when this is off.
    /// On by default: a translucent strip, mostly empty, shows the windows
    /// behind it far more plainly than the text-filled terminal does.
    static let keepsTabStripOpaque = "windowChromeKeepsTabStripOpaque"
    static let keepsTabStripOpaqueByDefault = true

    static var registrationValues: [String: Any] {
        [keepsTabStripOpaque: keepsTabStripOpaqueByDefault]
    }
}

/// Follows System Settings → Accessibility → Display → Reduce transparency.
/// When it is on, every terminal and its chrome draw opaque, as Terminal.app
/// does. The profile's opacity stays stored, so turning it off restores it.
@Observable
final class SystemTransparency {
    static let shared = SystemTransparency()

    private(set) var reducesTransparency: Bool
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(reducesTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        self.reducesTransparency = reducesTransparency
    }

    /// Starts following the system switch. Called once at launch; tests build
    /// their own instance and never observe.
    func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard reduces != reducesTransparency else { return }
        reducesTransparency = reduces
        TerminalSessionRegistry.shared.applyAppearanceToAll()
    }

    /// The opacity a terminal draws with.
    func backgroundOpacity(_ requested: Double) -> Double {
        reducesTransparency ? 1 : requested
    }
}

enum WindowChromeOpacity {
    /// The tab strip is opaque when the app or the profile pins it, and
    /// otherwise as transparent as the terminal it sits against.
    static func tabStrip(terminalOpacity: Double, profilePinsOpaque: Bool, appPinsOpaque: Bool) -> Double {
        profilePinsOpaque || appPinsOpaque ? 1 : terminalOpacity
    }
}
