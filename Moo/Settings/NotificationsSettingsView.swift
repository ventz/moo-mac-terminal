//
//  NotificationsSettingsView.swift
//  Moo
//
//  App-wide choices for how a pane that asks for the user gets noticed. The
//  list in Window → Notifications is not optional; everything else is.
//

import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    // Defaults must match AttentionDefaults and AttentionAlertSettings.
    @AppStorage(AttentionDefaults.showsBanners) private var showsBanners = true
    @AppStorage(AttentionDefaults.showsStatusItem) private var showsStatusItem = true
    @AppStorage(AttentionDefaults.showsDockBadge) private var showsDockBadge = true
    @AppStorage(AttentionDefaults.dockBounce) private var dockBounce: AttentionDockBounce = .once
    @AppStorage(AttentionDefaults.marksWaiting) private var marksWaiting = true
    @AppStorage(AttentionDefaults.sound) private var sound = AttentionAlertSettings.defaultSound
    @AppStorage(AttentionDefaults.soundVolume) private var volume = 1.0
    @AppStorage(AttentionDefaults.audioTiming) private var audioTiming: AttentionAudioTiming = .always
    @AppStorage(AttentionDefaults.speaksMessage) private var speaksMessage = false

    @State private var bannersDenied = false
    private let installedSounds = AttentionAlertSettings.availableSounds()

    var body: some View {
        Form {
            Section {
                Text("Programs such as Claude Code can tell Moo they are waiting for you. "
                     + "Moo always lists these in Window → Notifications; choose what else happens "
                     + "when one arrives. Nothing fires for the pane you are already looking at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visual") {
                Toggle("Show system banners", isOn: $showsBanners)
                if showsBanners, bannersDenied {
                    HStack {
                        Text("Banners are turned off for Moo in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings", action: openSystemNotificationSettings)
                    }
                }
                Toggle("Show in menu bar", isOn: $showsStatusItem)
                Toggle("Show unread count on the Dock icon", isOn: $showsDockBadge)
                Picker("Bounce the Dock icon", selection: $dockBounce) {
                    ForEach(AttentionDockBounce.allCases) { bounce in
                        Text(bounce.title).tag(bounce)
                    }
                }
                Toggle("Mark waiting tabs and projects", isOn: $marksWaiting)
            }

            Section("Audio") {
                Picker("Sound", selection: $sound) {
                    Text("None").tag(AttentionAlertSettings.noSound)
                    Divider()
                    ForEach(soundChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $volume, in: 0...1)
                        Button {
                            AttentionAlerts.shared.play(sound, volume: volume)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        .help("Play the sound")
                    }
                }
                .disabled(sound.isEmpty)
                Toggle("Speak the message aloud", isOn: $speaksMessage)
                Picker("Play", selection: $audioTiming) {
                    ForEach(AttentionAudioTiming.allCases) { timing in
                        Text(timing.title).tag(timing)
                    }
                }
                .disabled(sound.isEmpty && !speaksMessage)
            }

            Section {
                HStack {
                    Text("Fires every alert turned on above, without adding to the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Send Test Notification") {
                        AttentionCenter.shared.sendTestAlert()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshBannerAuthorization() }
        .onChange(of: showsBanners) {
            Task { await refreshBannerAuthorization() }
        }
        .onChange(of: showsDockBadge) {
            AttentionCenter.shared.refreshDockBadge()
        }
        .onChange(of: marksWaiting) {
            ProjectRuntime.shared.invalidate()
        }
        .onChange(of: sound) {
            AttentionAlerts.shared.play(sound, volume: volume)
        }
    }

    /// Keeps a chosen sound in the list even if its file has since gone.
    private var soundChoices: [String] {
        guard !sound.isEmpty, !installedSounds.contains(sound) else { return installedSounds }
        return installedSounds + [sound]
    }

    private func refreshBannerAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        bannersDenied = status == .denied
    }

    private func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
