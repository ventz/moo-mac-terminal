//
//  UpdatesSettingsView.swift
//  Moo
//
//  Settings → Updates: Sparkle's automatic checks, when it last looked, and a
//  manual check. Sparkle keeps its own settings in UserDefaults, so they are
//  read from and written to the updater rather than through @AppStorage.
//

import Sparkle
import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject private var model = UpdaterModel.shared
    @State private var checksAutomatically = false
    @State private var downloadsAutomatically = false

    var body: some View {
        Form {
            if model.updatesEnabled {
                Section {
                    Toggle("Automatically check for updates", isOn: $checksAutomatically)
                        .onChange(of: checksAutomatically) { _, enabled in
                            model.updater.automaticallyChecksForUpdates = enabled
                        }
                    Toggle("Download and install updates automatically", isOn: $downloadsAutomatically)
                        .onChange(of: downloadsAutomatically) { _, enabled in
                            model.updater.automaticallyDownloadsUpdates = enabled
                        }
                        .disabled(!checksAutomatically)
                    LabeledContent("Last checked") {
                        Text(Self.lastCheckedText(model.lastUpdateCheckDate))
                            .foregroundStyle(.secondary)
                    }
                    Button("Check for Updates Now") {
                        model.checkForUpdates()
                    }
                    .disabled(!model.canCheckForUpdates)
                } footer: {
                    Text("Updates are signed, notarized and verified before they install. A downloaded update installs when you quit Moo.")
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
            checksAutomatically = model.updater.automaticallyChecksForUpdates
            downloadsAutomatically = model.updater.automaticallyDownloadsUpdates
        }
    }

    static func lastCheckedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
