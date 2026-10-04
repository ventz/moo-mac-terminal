//
//  UpdatesSettingsView.swift
//  Moo
//
//  Settings → Updates: how a new version is announced (window, dot only, or
//  no checks), automatic installs, when Moo last looked, and a manual check.
//  Sparkle keeps its own settings in UserDefaults, so they are read from and
//  written to the updater rather than through @AppStorage.
//

import Sparkle
import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject private var model = UpdaterModel.shared
    @State private var alertMode = UpdateAlertMode.window
    @State private var downloadsAutomatically = false

    var body: some View {
        Form {
            if model.updatesEnabled {
                Section {
                    Picker("When a new version is out:", selection: $alertMode) {
                        ForEach(UpdateAlertMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .settingsAnchor(.updates, "When a new version is out:")
                    .pickerStyle(.radioGroup)
                    .onChange(of: alertMode) { _, mode in
                        // onAppear loading the stored mode fires this too;
                        // only a real choice is written, or a Mac that never
                        // picked one would have "off" stored for it.
                        guard mode != model.alertMode else { return }
                        model.setAlertMode(mode)
                        if mode == .window {
                            // Sparkle reports false while checks are off, so
                            // the real value is only readable now.
                            downloadsAutomatically = model.updater.automaticallyDownloadsUpdates
                        }
                    }
                    // A disabled macOS switch looks almost the same as an off
                    // one, so the label dims too and says why it is unavailable.
                    Toggle(isOn: $downloadsAutomatically) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download and install updates automatically")
                                .foregroundStyle(alertMode == .window ? .primary : .secondary)
                            if alertMode != .window {
                                Text("Available with \u{201C}Show the update window automatically\u{201D}.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                        .onChange(of: downloadsAutomatically) { _, enabled in
                            guard enabled != model.updater.automaticallyDownloadsUpdates else { return }
                            model.updater.automaticallyDownloadsUpdates = enabled
                        }
                        .disabled(alertMode != .window)
                        .settingsAnchor(.updates, "Download and install updates automatically")
                    LabeledContent("Last checked") {
                        Text(Self.lastCheckedText(model.lastUpdateCheckDate))
                            .foregroundStyle(.secondary)
                    }
                    Button("Check for Updates Now") {
                        model.checkForUpdates()
                    }
                    .settingsAnchor(.updates, "Check for Updates Now")
                    .disabled(!model.canCheckForUpdates)
                } footer: {
                    Text("""
                        A purple dot in the title bar marks a waiting update; click it for details.
                        \u{201C}Only show the purple dot\u{201D} still checks once a day, quietly.
                        Updates are signed, notarized and verified before they install.
                        A downloaded update installs when you quit Moo.
                        """)
                }
            } else {
                Section {
                    Text("This build does not update itself. Development builds never check for updates.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            guard model.updatesEnabled else { return }
            alertMode = model.alertMode
            downloadsAutomatically = model.updater.automaticallyDownloadsUpdates
        }
    }

    static func lastCheckedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
