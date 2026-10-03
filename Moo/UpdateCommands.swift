//
//  UpdateCommands.swift
//  Moo
//
//  In-app updates through Sparkle. The app ships as a Developer ID signed app
//  outside the Mac App Store, so Sparkle checks an appcast feed named by
//  SUFeedURL in Info.plist.
//
//  The feed is Moo's own (moo.vpetkov.net). Without SUFeedURL the updater
//  never starts, and it must never point at upstream's feed: that would have
//  Sparkle install the upstream app over Moo.
//

import Combine
import Sparkle
import SwiftUI

enum UpdatePolicy {
    static var permitsUpdates: Bool {
#if DEBUG
        false
#else
        permitsUpdates(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleNames: [
                Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ].compactMap { $0 },
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        )
#endif
    }

    static func permitsUpdates(
        bundleIdentifier: String?,
        bundleNames: [String],
        feedURL: String?
    ) -> Bool {
        // No feed, no updater. Checked first because it is the fork's switch.
        guard let feedURL, !feedURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        if bundleIdentifier?.lowercased().hasSuffix(".debug") == true {
            return false
        }

        return !bundleNames.contains { name in
            let lowercaseName = name.lowercased()
            return lowercaseName == "debug" || lowercaseName.hasSuffix(" debug")
        }
    }
}

enum UpdateDefaults {
    /// How Moo tells you about a new version (UpdateAlertMode). Kept out of
    /// profile documents: see AppSettings.securitySensitiveKeys.
    static let alertMode = "updatesAlertMode"
}

/// Settings → Updates → "When a new version is out". Sparkle's own
/// automatic checks are on only for `.window`; `.dot` has Moo check quietly
/// with checkForUpdateInformation, which finds an update without showing any
/// window, so only the titlebar dot appears.
enum UpdateAlertMode: String, CaseIterable, Identifiable {
    case window
    case dot
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .window: return "Show the update window automatically"
        case .dot: return "Only show the purple dot"
        case .off: return "Don't check for updates"
        }
    }

    /// The stored choice. Before it existed, Sparkle's own switch was the
    /// only one, so a Mac that had turned checks off stays off.
    static func current(
        _ defaults: UserDefaults = .standard,
        sparkleChecksAutomatically: Bool
    ) -> UpdateAlertMode {
        defaults.string(forKey: UpdateDefaults.alertMode).flatMap(Self.init(rawValue:))
            ?? (sparkleChecksAutomatically ? .window : .off)
    }

    /// Whether a quiet check is due: never checked, or the last one is a
    /// day old. Sparkle records every check, quiet or not.
    static func quietCheckIsDue(lastCheck: Date?, now: Date = Date(), interval: TimeInterval = 86_400) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// Owns the one updater instance for the process.
///
/// In an eligible release bundle, the updater starts with the app, so a
/// scheduled check runs without the user opening the menu.
/// `SUEnableAutomaticChecks` is on in Info.plist: checks start without
/// Sparkle's second-launch permission prompt, and Settings → Updates turns
/// them off.
@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()

    let controller: SPUStandardUpdaterController
    let updatesEnabled: Bool

    /// False while a check is in progress, which is when the menu item is disabled.
    @Published private(set) var canCheckForUpdates = false
    /// When the last check finished; nil before the first one.
    @Published private(set) var lastUpdateCheckDate: Date?
    /// The newer version the last check found and the user has neither
    /// installed nor skipped. Drives the titlebar's update dot.
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// Sparkle holds its delegate weakly.
    private let delegate = UpdaterDelegate()

    private init() {
        updatesEnabled = UpdatePolicy.permitsUpdates
        controller = SPUStandardUpdaterController(
            startingUpdater: updatesEnabled,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.model = self
#if DEBUG
        // Debug builds never check, so this is the only way to see the dot:
        // `open --env MOO_PREVIEW_UPDATE_VERSION=9.9.9 Moo.app`.
        if let version = ProcessInfo.processInfo.environment["MOO_PREVIEW_UPDATE_VERSION"] {
            availableUpdate = AvailableUpdate(version: version, date: Date())
        }
#endif
        if updatesEnabled {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: DispatchQueue.main)
                .assign(to: &$lastUpdateCheckDate)
            apply(alertMode)
        }
    }

    var updater: SPUUpdater { controller.updater }

    /// Checks hourly whether a quiet check is due, while in `.dot` mode.
    private var quietCheckTimer: Timer?

    var alertMode: UpdateAlertMode {
        UpdateAlertMode.current(sparkleChecksAutomatically: updater.automaticallyChecksForUpdates)
    }

    func setAlertMode(_ mode: UpdateAlertMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: UpdateDefaults.alertMode)
        apply(mode)
    }

    private func apply(_ mode: UpdateAlertMode) {
        guard updatesEnabled else { return }
        updater.automaticallyChecksForUpdates = mode == .window
        quietCheckTimer?.invalidate()
        quietCheckTimer = nil
        guard mode == .dot else { return }
        // Shortly after launch, then hourly; each only checks once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.quietCheckIfDue()
        }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietCheckIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietCheckTimer = timer
    }

    private func quietCheckIfDue() {
        guard alertMode == .dot, updater.canCheckForUpdates,
              UpdateAlertMode.quietCheckIsDue(lastCheck: updater.lastUpdateCheckDate)
        else { return }
        updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    fileprivate func found(_ update: AvailableUpdate) {
        availableUpdate = update
    }

    fileprivate func clearAvailableUpdate() {
        availableUpdate = nil
    }
}

/// What the titlebar dot says about a pending update.
struct AvailableUpdate: Equatable {
    /// The longest version string shown; real ones are like "0.1.9".
    static let versionLimit = 32

    var version: String
    var date: Date?

    init(version: String, date: Date?) {
        self.version = version
        self.date = date
    }

    /// The version as the feed spells it, made safe to show. The feed's text
    /// is data even though the update itself is signed: controls and bidi
    /// overrides become spaces and the length is capped, so a tampered feed
    /// cannot put a paragraph of instructions inside Moo's own popover.
    init(feedVersion: String, date: Date?) {
        let cleaned = TerminalNotificationParser.clean(feedVersion, limit: Self.versionLimit)
        self.init(version: cleaned.isEmpty ? "a new version" : cleaned, date: date)
    }

    /// The running app's version, for "you have …".
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// Tracks whether an update is waiting. Sparkle still shows its own window
/// as before; this only keeps the dot in step with it. Sparkle calls its
/// delegate on the main thread.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var model: UpdaterModel?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let date = item.date
        MainActor.assumeIsolated {
            model?.found(AvailableUpdate(feedVersion: version, date: date))
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { model?.clearAvailableUpdate() }
    }

    /// "Remind Me Later" keeps the dot; installing or skipping the version
    /// clears it.
    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice != .dismiss else { return }
        MainActor.assumeIsolated { model?.clearAvailableUpdate() }
    }
}

struct UpdateCommands: Commands {
    @ObservedObject private var model = UpdaterModel.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if model.updatesEnabled {
                // Names a waiting update, so it is visible from the keyboard
                // and VoiceOver too, not only as the titlebar dot.
                Button(model.availableUpdate.map { "Update to Moo \($0.version)…" } ?? "Check for Updates…") {
                    model.checkForUpdates()
                }
                .disabled(!model.canCheckForUpdates)
            }
        }
    }
}
