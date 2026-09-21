import Foundation
import Testing
@testable import Moo

@MainActor
struct KeyRepeatTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "moo-key-repeat-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Key repeat is on unless someone turned it off: a terminal that does not
    /// repeat `hjkl` is the surprising behavior, not the other way round.
    @Test func keyRepeatIsOnByDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(KeyRepeat.isEnabled(in: defaults) == true)
        #expect(KeyboardDefaults.keyRepeatEnabledByDefault == true)
    }

    /// The setting and AppKit's switch are the same thing seen from opposite
    /// sides. Getting the polarity backwards is the easy mistake here, so it is
    /// pinned.
    @Test func enablingKeyRepeatDisablesPressAndHold() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        KeyRepeat.set(enabled: true, in: defaults)
        #expect(KeyRepeat.isEnabled(in: defaults) == true)
        #expect(defaults.bool(forKey: KeyRepeat.pressAndHoldKey) == false)

        KeyRepeat.set(enabled: false, in: defaults)
        #expect(KeyRepeat.isEnabled(in: defaults) == false)
        #expect(defaults.bool(forKey: KeyRepeat.pressAndHoldKey) == true)
    }

    /// Launch has to put the stored choice into effect before any terminal
    /// view exists, or the first keystrokes of a session behave differently
    /// from the rest.
    @Test func launchAppliesTheStoredChoice() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: KeyboardDefaults.keyRepeatEnabled)
        KeyRepeat.applyStoredSetting(in: defaults)
        #expect(defaults.bool(forKey: KeyRepeat.pressAndHoldKey) == true)

        defaults.set(true, forKey: KeyboardDefaults.keyRepeatEnabled)
        KeyRepeat.applyStoredSetting(in: defaults)
        #expect(defaults.bool(forKey: KeyRepeat.pressAndHoldKey) == false)
    }

    /// Never written to the global domain: the accent picker keeps working in
    /// every other app on the Mac.
    @Test func theOverrideIsScopedToThisApp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        KeyRepeat.set(enabled: true, in: defaults)
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        #expect(global[KeyRepeat.pressAndHoldKey] == nil)
    }
}
