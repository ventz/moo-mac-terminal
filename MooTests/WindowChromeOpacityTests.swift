import AppKit
import Testing
@testable import Moo

@MainActor
struct WindowChromeOpacityTests {
    @Test func tabStripFollowsTheTerminalUnlessPinned() {
        #expect(WindowChromeOpacity.tabStrip(terminalOpacity: 0.85, profilePinsOpaque: false, appPinsOpaque: false) == 0.85)
        #expect(WindowChromeOpacity.tabStrip(terminalOpacity: 0.85, profilePinsOpaque: true, appPinsOpaque: false) == 1)
        #expect(WindowChromeOpacity.tabStrip(terminalOpacity: 0.85, profilePinsOpaque: false, appPinsOpaque: true) == 1)
    }

    @Test func reduceTransparencyMakesTheTerminalOpaque() {
        #expect(SystemTransparency(reducesTransparency: false).backgroundOpacity(0.6) == 0.6)
        #expect(SystemTransparency(reducesTransparency: true).backgroundOpacity(0.6) == 1)
    }
}

@MainActor
struct WindowChromeDefaultsTests {
    @Test func tabStripIsOpaqueByDefault() {
        #expect(WindowChromeDefaults.keepsTabStripOpaqueByDefault)
        #expect(WindowChromeDefaults.registrationValues[WindowChromeDefaults.keepsTabStripOpaque] as? Bool == true)
    }

    @Test func titleBarFollowsTheThemeByDefault() throws {
        #expect(!TerminalProfile(name: "Stock").usesStandardTitlebar)
        let legacy = try JSONDecoder().decode(TerminalProfile.self, from: Data(#"{"name":"Legacy"}"#.utf8))
        #expect(!legacy.usesStandardTitlebar)
        var standard = TerminalProfile(name: "Standard")
        standard.usesStandardTitlebar = true
        let decoded = try JSONDecoder().decode(TerminalProfile.self, from: JSONEncoder().encode(standard))
        #expect(decoded.usesStandardTitlebar)
    }

    /// The standard title row is opaque and light in light mode, dark in dark
    /// mode, whatever the theme behind it.
    @Test func standardTitleBarIsPaintedInTheSystemWindowColor() throws {
        let light = TerminalWindowAppearance.standardTitlebarColor(in: NSAppearance(named: .aqua))
        let dark = TerminalWindowAppearance.standardTitlebarColor(in: NSAppearance(named: .darkAqua))
        let lightRGB = try #require(light.usingColorSpace(.sRGB))
        let darkRGB = try #require(dark.usingColorSpace(.sRGB))
        #expect(lightRGB.alphaComponent == 1 && darkRGB.alphaComponent == 1)
        #expect(lightRGB.brightnessComponent > 0.8)
        #expect(darkRGB.brightnessComponent < 0.3)
    }

    /// A standard title row takes the system's light or dark appearance.
    @Test func nativeTitleBarUsesTheSystemAppearance() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            #expect(TerminalWindowAppearance.systemAppearance(appearance)?.name == name)
        }
        // A vibrant appearance falls back to its plain counterpart.
        let vibrant = try #require(NSAppearance(named: .vibrantDark))
        #expect(TerminalWindowAppearance.systemAppearance(vibrant)?.name == .darkAqua)
    }

    /// Switching the option re-colors an open window; it is not skipped as a
    /// repeat of the theme already applied.
    @Test func togglingTheNativeTitleBarRefreshesTheWindow() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        try await Self.waitForMainQueue()
        let chrome = try #require(Self.titlebarContainer(in: window))
        #expect(chrome.appearance == nil)

        TerminalWindowAppearance.apply(theme: .fallback, usesStandardTitlebar: true, to: window)
        try await Self.waitForMainQueue()
        let system = TerminalWindowAppearance.systemAppearance()
        #expect(chrome.appearance?.name == system?.name)
        if #available(macOS 26.0, *) {
            let titlebar = try #require(Self.descendant(named: "NSTitlebarView", in: chrome))
            let painted = try #require(titlebar.layer?.backgroundColor)
            #expect(painted == TerminalWindowAppearance.standardTitlebarColor(in: system).cgColor)
        }

        TerminalWindowAppearance.apply(theme: .fallback, usesStandardTitlebar: false, to: window)
        try await Self.waitForMainQueue()
        #expect(chrome.appearance == nil)
        window.close()
    }

    private static func waitForMainQueue() async throws {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func titlebarContainer(in window: NSWindow) -> NSView? {
        window.contentView?.superview.flatMap { descendant(named: "NSTitlebarContainerView", in: $0) }
    }

    private static func descendant(named className: String, in view: NSView) -> NSView? {
        if view.className == className { return view }
        for subview in view.subviews {
            if let match = descendant(named: className, in: subview) { return match }
        }
        return nil
    }
}
