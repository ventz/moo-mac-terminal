import Darwin
import Foundation
import Testing
@testable import Moo

@MainActor
final class SecureKeyboardEntryTests {
    /// Stands in for the OS and the key pane.
    private final class Probe {
        var enables = 0
        var disables = 0
        var enableSucceeds = true
        var atPrompt = false
        var appActive = true
        var outstanding: Int { enables - disables }
    }

    private let suiteName = "SecureKeyboardEntryTests-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func make(_ probe: Probe, manual: Bool = false, automatic: Bool? = nil) -> SecureKeyboardEntry {
        defaults.set(manual, forKey: AppSettings.secureKeyboardEntry)
        if let automatic {
            defaults.set(automatic, forKey: AppSettings.secureKeyboardEntryAtPasswordPrompts)
        }
        return SecureKeyboardEntry(
            defaults: defaults,
            enableInput: {
                guard probe.enableSucceeds else { return false }
                probe.enables += 1
                return true
            },
            disableInput: { probe.disables += 1 },
            focusedPaneIsAtPasswordPrompt: { probe.atPrompt },
            isAppActive: { probe.appActive }
        )
    }

    @Test func aPasswordPromptTurnsItOnAndOffOnce() {
        let probe = Probe()
        let entry = make(probe)
        #expect(!entry.isActive)

        probe.atPrompt = true
        entry.checkPasswordPrompt()
        entry.checkPasswordPrompt()
        #expect(entry.isActive && entry.isProtectingPrompt)
        #expect(probe.enables == 1)

        probe.atPrompt = false
        entry.checkPasswordPrompt()
        #expect(!entry.isActive)
        #expect(probe.outstanding == 0)
    }

    @Test func manualAndPromptShareOneEnable() {
        let probe = Probe()
        let entry = make(probe, manual: true)
        #expect(probe.enables == 1)

        probe.atPrompt = true
        entry.checkPasswordPrompt()
        #expect(probe.outstanding == 1)

        probe.atPrompt = false
        entry.checkPasswordPrompt()
        #expect(entry.isActive)

        entry.isEnabled = false
        #expect(!entry.isActive)
        #expect(probe.outstanding == 0)
    }

    @Test func automaticModeNeverChangesTheUsersSwitch() {
        let probe = Probe()
        let entry = make(probe)
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        #expect(entry.isActive)
        #expect(!entry.isEnabled)
        #expect(defaults.bool(forKey: AppSettings.secureKeyboardEntry) == false)
    }

    @Test func turningTheSettingOffIgnoresPrompts() {
        let probe = Probe()
        let entry = make(probe, automatic: false)
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        #expect(!entry.isActive)
        #expect(probe.enables == 0)
    }

    @Test func leavingTheAppReleasesAPromptsHold() {
        let probe = Probe()
        let entry = make(probe)
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        #expect(entry.isActive)

        probe.appActive = false
        entry.refreshPromptWatching()
        #expect(!entry.isActive)
        #expect(probe.outstanding == 0)
    }

    @Test func theManualSwitchLetsGoInTheBackground() {
        let probe = Probe()
        let entry = make(probe, manual: true)
        #expect(entry.isActive)
        probe.appActive = false
        entry.refreshPromptWatching()
        #expect(!entry.isActive)
        #expect(entry.isEnabled)
        probe.appActive = true
        entry.refreshPromptWatching()
        #expect(entry.isActive)
        #expect(probe.outstanding == 1)
    }

    @Test func aFailedEnableAtAPromptClaimsNothingAndRetries() {
        let probe = Probe()
        let entry = make(probe, manual: false)
        probe.enableSucceeds = false
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        #expect(!entry.isActive)
        #expect(!entry.isProtectingPrompt)

        probe.enableSucceeds = true
        entry.checkPasswordPrompt()
        #expect(entry.isActive && entry.isProtectingPrompt)
        #expect(probe.outstanding == 1)
    }

    @Test func reloadingSettingsDuringAPromptKeepsOneEnable() {
        let probe = Probe()
        let entry = make(probe)
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        defaults.set(true, forKey: AppSettings.secureKeyboardEntry)
        entry.reloadFromDefaults()
        #expect(probe.outstanding == 1)
        probe.atPrompt = false
        entry.checkPasswordPrompt()
        #expect(entry.isActive)
        #expect(probe.outstanding == 1)
    }

    @Test func nothingTurnsItBackOnAfterTermination() {
        let probe = Probe()
        let entry = make(probe)
        probe.atPrompt = true
        entry.checkPasswordPrompt()
        entry.disableForTermination()
        entry.checkPasswordPrompt()
        entry.refreshPromptWatching()
        #expect(!entry.isActive)
        #expect(probe.outstanding == 0)
    }

    @Test func aFailedManualEnableTurnsTheSwitchBackOff() {
        let probe = Probe()
        probe.enableSucceeds = false
        let entry = make(probe)
        entry.isEnabled = true
        #expect(!entry.isEnabled)
        #expect(!entry.isActive)
        #expect(!defaults.bool(forKey: AppSettings.secureKeyboardEntry))
    }

    @Test func terminationDisablesWhatWasEnabled() {
        let probe = Probe()
        let entry = make(probe, manual: true)
        entry.disableForTermination()
        #expect(probe.outstanding == 0)
        entry.disableForTermination()
        #expect(probe.disables == 1)
    }

    @Test func passwordModeIsEchoOffWithLineEditing() {
        #expect(TerminalProcessInspector.isPasswordMode(localFlags: tcflag_t(ICANON)))
        #expect(!TerminalProcessInspector.isPasswordMode(localFlags: tcflag_t(ICANON | ECHO)))
        #expect(!TerminalProcessInspector.isPasswordMode(localFlags: 0))
    }
}
