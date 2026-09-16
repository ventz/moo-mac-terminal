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

    private init() {
        updatesEnabled = UpdatePolicy.permitsUpdates
        controller = SPUStandardUpdaterController(
            startingUpdater: updatesEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if updatesEnabled {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: DispatchQueue.main)
                .assign(to: &$lastUpdateCheckDate)
        }
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct UpdateCommands: Commands {
    @ObservedObject private var model = UpdaterModel.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if model.updatesEnabled {
                Button("Check for Updates…") {
                    model.checkForUpdates()
                }
                .disabled(!model.canCheckForUpdates)
            }
        }
    }
}
