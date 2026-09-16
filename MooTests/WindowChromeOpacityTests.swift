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
}
