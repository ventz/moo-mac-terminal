//
//  AppSettings.swift
//  Moo
//
//  Every app-wide setting Moo keeps in UserDefaults, so a .mooprofile can
//  carry all of them: export writes their current values, import can apply
//  them. AppSettingsTests scans the source and fails when a defaults key is
//  in neither `all` nor `excludedKeys`, so a new setting cannot be missed.
//

import Foundation

/// A setting's value as it appears in a profile document: a plain JSON scalar
enum AppSettingValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// The value to store for a setting of this kind. JSON writes 150.0 as
    /// 150, so a whole number reads back as .int and still fits a double.
    func storedValue(for kind: AppSetting.Kind) -> Any? {
        switch (kind, self) {
        case (.bool, .bool(let value)): return value
        case (.int, .int(let value)): return value
        case (.double, .double(let value)): return value
        case (.double, .int(let value)): return Double(value)
        case (.string, .string(let value)): return value
        default: return nil
        }
    }
}

struct AppSetting {
    enum Kind { case bool, int, double, string }

    let key: String
    let kind: Kind
}

enum AppSettings {
    static let startupProfileID = "startupProfileID"
    static let secureKeyboardEntry = "SecureKeyboardEntry"
    static let secureKeyboardEntryAtPasswordPrompts = "SecureKeyboardEntryAtPasswordPrompts"

    static let all: [AppSetting] = [
        // General. What opens at launch is deliberately absent: see
        // securitySensitiveKeys.
        AppSetting(key: "newTabsUseCurrentDirectory", kind: .bool),
        AppSetting(key: "newTabsUseCurrentProfile", kind: .bool),
        AppSetting(key: "useCommandDigitsForTabs", kind: .bool),
        AppSetting(key: "restoredRowsLimit", kind: .int),
        AppSetting(key: "useMetalRenderer", kind: .bool),
        AppSetting(key: KeyboardDefaults.keyRepeatEnabled, kind: .bool),
        AppSetting(key: WorkspaceRestoreDefaults.restoresOnLaunch, kind: .bool),
        // LogHostOutput, Secure Keyboard Entry, the web inspector, content
        // blocking, update checking and images from local sources are
        // deliberately absent: see securitySensitiveKeys.
        AppSetting(key: LinkRoutingDefaults.opensLinksInApp, kind: .bool),
        AppSetting(key: MarkdownPreviewDefaults.followsTerminalTheme, kind: .bool),
        AppSetting(key: MarkdownPreviewDefaults.opensLinksInNewTab, kind: .bool),
        AppSetting(key: WindowChromeDefaults.keepsTabStripOpaque, kind: .bool),
        // Projects
        AppSetting(key: ProjectSidebarDefaults.isVisible, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.width, kind: .double),
        AppSetting(key: ProjectSidebarDefaults.showsStatus, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.showsBranch, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.showsPath, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.showsAccent, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.drawsDivider, kind: .bool),
        AppSetting(key: ProjectSidebarDefaults.commandDigitsTarget, kind: .string),
        // Notifications
        AppSetting(key: AttentionDefaults.showsBanners, kind: .bool),
        AppSetting(key: AttentionDefaults.showsStatusItem, kind: .bool),
        AppSetting(key: AttentionDefaults.showsDockBadge, kind: .bool),
        AppSetting(key: AttentionDefaults.dockBounce, kind: .string),
        AppSetting(key: AttentionDefaults.marksWaiting, kind: .bool),
        AppSetting(key: AttentionDefaults.sound, kind: .string),
        AppSetting(key: AttentionDefaults.soundVolume, kind: .double),
        AppSetting(key: AttentionDefaults.audioTiming, kind: .string),
        AppSetting(key: AttentionDefaults.speaksMessage, kind: .bool),
        AppSetting(key: AttentionDefaults.notifiesLongCommands, kind: .bool),
        AppSetting(key: AttentionDefaults.longCommandSeconds, kind: .double),
        AppSetting(key: AttentionDefaults.marksFailedCommands, kind: .bool),
        // HerdrDefaults.showsAgents is deliberately absent: see
        // securitySensitiveKeys.
        AppSetting(key: HerdrDefaults.alertsWhenBlocked, kind: .bool),
        AppSetting(key: HerdrDefaults.alertsWhenFinished, kind: .bool),
        // Theme browser
        AppSetting(key: "themeBrowserDisplayMode", kind: .string),
        AppSetting(key: "themeBrowserPlotMode", kind: .string),
        AppSetting(key: ThemeProjection3D.perceptualChromaDefaultsKey, kind: .bool),
    ]

    /// Settings that a profile document never carries, in either direction:
    /// export leaves them out and import ignores them even when a file holds
    /// them, so they stay as this Mac has them. A .mooprofile is shared
    /// socially, as "a theme", and applying one must not be able to weaken
    /// the Mac it lands on:
    /// - LogHostOutput would start recording every pane's raw output to disk.
    /// - Secure Keyboard Entry guards typed passwords from other apps; a file
    ///   could switch it off.
    /// - The web inspector exposes browser tabs' pages and storage.
    /// - Update checking: a file could stop the Mac hearing about security
    ///   updates.
    /// - Startup (what opens at launch, with which profile or window group):
    ///   a file could make every launch open a profile it brought, one whose
    ///   shell runs a command, even after that profile was imported as
    ///   appearance only and another one picked.
    /// - Content blocking: a file could switch off the ad and tracker blocker
    ///   in browser tabs.
    /// - herdr: "Show herdr agents" is consent for Moo to read other
    ///   processes' arguments and connect to local sockets; a file must not
    ///   give it on the user's behalf.
    /// - Images from local files and shared memory let terminal output probe
    ///   the Mac's files and delete shared memory objects; a file must not
    ///   switch them on.
    /// Pinned by AppSettingsTests.importNeverChangesSecuritySensitiveSettings.
    static let securitySensitiveKeys: Set<String> = [
        "LogHostOutput",
        secureKeyboardEntry,
        secureKeyboardEntryAtPasswordPrompts,
        "webInspectorEnabled",
        UpdateDefaults.alertMode,
        "startupMode",
        startupProfileID,
        "startupWindowGroupID",
        ContentBlockingDefaults.enabledKey,
        HerdrDefaults.showsAgents,
        TerminalImageDefaults.allowsLocalSources,
    ]

    /// Keys a profile document never carries: state or identity, which stays
    /// on this Mac, and the security-sensitive settings above.
    static let excludedKeys: Set<String> = securitySensitiveKeys.union(stateKeys)

    /// Keys that are state or identity, not settings, and so stay on this Mac
    private static let stateKeys: Set<String> = [
        PreferenceMigrator.schemaKey,                // the defaults schema version
        "browserDataStoreIdentifier",                // names this Mac's browser cookie store
        ProjectSidebarDefaults.selectedProjectID,    // which project was last selected
        "lastTerminalWindowFrame",                   // where the last window was
        "lastTerminalWindowFrameSize",
        AttentionCenter.itemIDKey,                   // a notification's userInfo key
        "drawsBackground",                           // a WKWebView key-value, not a default
        KeyRepeat.pressAndHoldKey,                   // AppKit's own key, derived from
                                                     // keyboardKeyRepeatEnabled at launch
    ]

    /// The current value of every setting that has one, defaults included, so
    /// importing reproduces what this Mac shows
    static func snapshot(from defaults: UserDefaults = .standard) -> [String: AppSettingValue] {
        var values: [String: AppSettingValue] = [:]
        for setting in all {
            let object = defaults.object(forKey: setting.key)
            switch setting.kind {
            case .bool: (object as? Bool).map { values[setting.key] = .bool($0) }
            case .int: (object as? Int).map { values[setting.key] = .int($0) }
            case .double: (object as? Double).map { values[setting.key] = .double($0) }
            case .string: (object as? String).map { values[setting.key] = .string($0) }
            }
        }
        return values
    }

    /// Makes every setting match the document: a setting it lacks, or holds
    /// with the wrong type, returns to its default. Keys Moo does not know,
    /// and the security-sensitive ones, are ignored.
    static func apply(_ values: [String: AppSettingValue], to defaults: UserDefaults = .standard) {
        for setting in all {
            guard let stored = values[setting.key]?.storedValue(for: setting.kind) else {
                defaults.removeObject(forKey: setting.key)
                continue
            }
            defaults.set(stored, forKey: setting.key)
        }
    }
}
