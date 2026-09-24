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
        // General
        AppSetting(key: "startupMode", kind: .string),
        AppSetting(key: startupProfileID, kind: .string),
        AppSetting(key: "startupWindowGroupID", kind: .string),
        AppSetting(key: "newTabsUseCurrentDirectory", kind: .bool),
        AppSetting(key: "newTabsUseCurrentProfile", kind: .bool),
        AppSetting(key: "useCommandDigitsForTabs", kind: .bool),
        AppSetting(key: "restoredRowsLimit", kind: .int),
        AppSetting(key: "useMetalRenderer", kind: .bool),
        AppSetting(key: KeyboardDefaults.keyRepeatEnabled, kind: .bool),
        AppSetting(key: secureKeyboardEntry, kind: .bool),
        AppSetting(key: secureKeyboardEntryAtPasswordPrompts, kind: .bool),
        AppSetting(key: WorkspaceRestoreDefaults.restoresOnLaunch, kind: .bool),
        // LogHostOutput is deliberately absent. A profile document is shared
        // socially, as "a theme", and applying one must not be able to start
        // recording every pane's raw output to disk.
        AppSetting(key: "webInspectorEnabled", kind: .bool),
        AppSetting(key: LinkRoutingDefaults.opensLinksInApp, kind: .bool),
        AppSetting(key: MarkdownPreviewDefaults.followsTerminalTheme, kind: .bool),
        AppSetting(key: WindowChromeDefaults.keepsTabStripOpaque, kind: .bool),
        AppSetting(key: ContentBlockingDefaults.enabledKey, kind: .bool),
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
        // Theme browser
        AppSetting(key: "themeBrowserDisplayMode", kind: .string),
        AppSetting(key: "themeBrowserPlotMode", kind: .string),
        AppSetting(key: ThemeProjection3D.perceptualChromaDefaultsKey, kind: .bool),
    ]

    /// Keys that are state or identity, not settings, and so stay on this Mac
    static let excludedKeys: Set<String> = [
        PreferenceMigrator.schemaKey,                // the defaults schema version
        "browserDataStoreIdentifier",                // names this Mac's browser cookie store
        ProjectSidebarDefaults.selectedProjectID,    // which project was last selected
        "lastTerminalWindowFrame",                   // where the last window was
        "lastTerminalWindowFrameSize",
        AttentionCenter.itemIDKey,                   // a notification's userInfo key
        "drawsBackground",                           // a WKWebView key-value, not a default
        KeyRepeat.pressAndHoldKey,                   // AppKit's own key, derived from
                                                     // keyboardKeyRepeatEnabled at launch
        "LogHostOutput",                             // never travels in a profile: see `all`
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
    /// with the wrong type, returns to its default. Keys Moo does not know are
    /// ignored. profileIDs maps an exported profile id to the one it was
    /// imported as, so a startup profile still points at it.
    static func apply(
        _ values: [String: AppSettingValue],
        to defaults: UserDefaults = .standard,
        profileIDs: [String: String] = [:]
    ) {
        for setting in all {
            guard var stored = values[setting.key]?.storedValue(for: setting.kind) else {
                defaults.removeObject(forKey: setting.key)
                continue
            }
            if setting.key == startupProfileID, let id = stored as? String, let mapped = profileIDs[id] {
                stored = mapped
            }
            defaults.set(stored, forKey: setting.key)
        }
    }
}
