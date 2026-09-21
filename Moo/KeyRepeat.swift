import Foundation

enum KeyboardDefaults {
    /// App-wide: repeat a character while its key is held down.
    ///
    /// On by default, because a terminal is not a word processor. macOS's
    /// press-and-hold feature waits on a letter key to decide whether to offer
    /// the accent picker, and while it waits the key does not repeat at all —
    /// so holding `j` in vim, or in any TUI that uses `hjkl`, does nothing.
    /// Arrow keys are unaffected, which is what makes the behavior so
    /// confusing to diagnose: navigation repeats, letters do not.
    static let keyRepeatEnabled = "keyboardKeyRepeatEnabled"
    static let keyRepeatEnabledByDefault = true

    static var registrationValues: [String: Any] {
        [keyRepeatEnabled: keyRepeatEnabledByDefault]
    }
}

/// Turns macOS's press-and-hold on and off for Moo alone.
///
/// AppKit reads `ApplePressAndHoldEnabled` from the standard defaults when it
/// interprets a key event. Writing it into *this app's* domain overrides the
/// global value for Moo and nothing else — the accent picker keeps working
/// everywhere else on the Mac, which is why this is preferable to telling
/// people to run `defaults write -g ApplePressAndHoldEnabled -bool false`.
enum KeyRepeat {
    /// AppKit's own key. Not ours, so it is spelled out rather than guessed at.
    static let pressAndHoldKey = "ApplePressAndHoldEnabled"

    /// Whether key repeat is switched on, according to the stored setting.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: KeyboardDefaults.keyRepeatEnabled) as? Bool
            ?? KeyboardDefaults.keyRepeatEnabledByDefault
    }

    /// Store the choice and put it into effect.
    static func set(enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: KeyboardDefaults.keyRepeatEnabled)
        apply(enabled: enabled, in: defaults)
    }

    /// Put the stored choice into effect. Called at launch, before any terminal
    /// view exists, so the first keystroke already behaves correctly.
    static func applyStoredSetting(in defaults: UserDefaults = .standard) {
        apply(enabled: isEnabled(in: defaults), in: defaults)
    }

    /// Key repeat and press-and-hold are the same switch seen from opposite
    /// sides: enabling one disables the other.
    static func apply(enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: pressAndHoldKey)
    }
}
