//
//  HerdrSettingsSection.swift
//  Moo
//
//  Settings → Notifications → herdr: the opt-in for reading herdr agents,
//  their alerts, and a status line that finds herdr and explains what to do
//  when it is missing.
//

import AppKit
import SwiftUI

struct HerdrSettingsSection: View {
    @AppStorage(HerdrDefaults.showsAgents) private var showsAgents = HerdrDefaults.defaultShowsAgents
    @AppStorage(HerdrDefaults.alertsWhenBlocked) private var alertsWhenBlocked =
        HerdrDefaults.defaultAlertsWhenBlocked
    @AppStorage(HerdrDefaults.alertsWhenFinished) private var alertsWhenFinished =
        HerdrDefaults.defaultAlertsWhenFinished
    @AppStorage(HerdrDefaults.showsAgentPanel) private var showsAgentPanel =
        HerdrDefaults.defaultShowsAgentPanel

    @State private var installation = HerdrInstallation.checking
    /// Bumped when Moo becomes active again, so an install or upgrade run in
    /// a tab shows up when the user comes back.
    @State private var recheck = 0
    private let monitor = HerdrMonitor.shared

    var body: some View {
        Section {
            Toggle(isOn: $showsAgents) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show herdr agents")
                    statusLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsAnchor(.notifications, "Show herdr agents")
            if !showsAgents {
                EmptyView()
            } else if case .missing(let brew) = installation, monitor.liveCoreSessionCount == 0 {
                // With the Herdr app's herdr-core running, herdr 0.9 is
                // optional: nothing to install.
                installRow(brew: brew)
            } else if case .tooOld(let path, _) = installation, HerdrInstallation.isHomebrewPath(path) {
                commandRow(HerdrInstallation.upgradeCommand, action: "Upgrade in New Tab")
            }
            Toggle("Show the agent panel in the sidebar", isOn: $showsAgentPanel)
                .settingsAnchor(.notifications, "Show the agent panel in the sidebar")
                .disabled(!showsAgents)
            Toggle("Alert when a herdr agent needs you", isOn: $alertsWhenBlocked)
                .settingsAnchor(.notifications, "Alert when a herdr agent needs you")
                .disabled(!showsAgents)
            Toggle("Alert when a herdr agent finishes", isOn: $alertsWhenFinished)
                .settingsAnchor(.notifications, "Alert when a herdr agent finishes")
                .disabled(!showsAgents)
        } header: {
            Text("herdr")
        } footer: {
            Text("""
                herdr runs coding agents in terminals it keeps alive (herdr.dev).
                On: agents in a herdr running in a Moo tab are listed under that tab's project, and every agent, including those the Herdr app runs through herdr-core, is listed in the sidebar's agent panel.
                Moo only reads herdr's local sockets and asks herdr to focus a pane; it never types into herdr. Clicking a Herdr app agent opens it in a new tab with hc attach.
                herdr infers status from the screen, so its entries say "detected by herdr".
                herdr's own alerts are separate and need delivery = "terminal" in herdr's config, which Moo does not edit.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Only once the user has turned it on: looking for herdr runs it.
        .task(id: [showsAgents ? 1 : 0, recheck]) {
            guard showsAgents else { return }
            installation = await HerdrInstallation.check()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck &+= 1
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !showsAgents {
            Text("Off: Moo does not look for herdr.")
        } else {
            installationLine
        }
    }

    @ViewBuilder
    private var installationLine: some View {
        if monitor.liveCoreSessionCount > 0 {
            Text(coreSummary)
            // herdr 0.9 is optional beside herdr-core, but a too-old one in
            // a Moo tab is still worth saying.
            if case .tooOld = installation { herdrInstallationLine }
        } else {
            herdrInstallationLine
        }
    }

    /// "herdr-core · 3 agents", and the herdr 0.9 summary when a herdr
    /// runs in a Moo tab too.
    private var coreSummary: String {
        _ = monitor.revision
        let agents = monitor.coreAgentCount
        var parts = ["herdr-core", agents == 1 ? "1 agent" : "\(agents) agents"]
        if monitor.liveSessionCount > 0 {
            let more = monitor.agentCount
            parts.append("herdr in a Moo tab: " + (more == 1 ? "1 agent" : "\(more) agents"))
        }
        if let refusal = monitor.refusal {
            parts.append("not connected: \(refusal)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var herdrInstallationLine: some View {
        switch installation {
        case .checking:
            Text("Looking for herdr…")
        case .found(let path, let version):
            Text("herdr \(version) at \(path)" + sessionSummary)
        case .tooOld(let path, let version) where version == "unknown":
            Text("herdr at \(path) did not report a version; Moo needs 0.9 or later.")
        case .tooOld(let path, let version):
            Text("herdr \(version) at \(path) is too old; Moo needs 0.9 or later.")
        case .missing(let brew):
            if brew == nil {
                Text("herdr isn't installed. Homebrew isn't either; see herdr's install page.")
            } else {
                Text("herdr isn't installed.")
            }
        }
    }

    /// " · 2 agents" while on and connected, or why it is not connected.
    private var sessionSummary: String {
        _ = monitor.revision
        guard showsAgents else { return "" }
        if let refusal = monitor.refusal {
            return ". Not connected: \(refusal)."
        }
        var parts: [String] = []
        let sessions = monitor.liveSessionCount
        if sessions == 0 {
            parts.append("no herdr running in a Moo tab")
        } else {
            let agents = monitor.agentCount
            parts.append(agents == 1 ? "1 agent" : "\(agents) agents")
        }
        if monitor.remoteHostCount > 0 {
            parts.append("remote sessions not shown yet")
        }
        return " · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func installRow(brew: String?) -> some View {
        if brew != nil {
            commandRow(HerdrInstallation.installCommand, action: "Install in New Tab")
        } else {
            HStack {
                Spacer()
                Button("Open herdr's Install Page") {
                    NSWorkspace.shared.open(HerdrInstallation.installPage)
                }
            }
        }
    }

    /// The command, a Copy button, and a new tab with the command typed but
    /// not run.
    private func commandRow(_ command: String, action: String) -> some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            Button(action) {
                HerdrInstallation.typeInNewTab(command)
            }
            .help("Opens a tab with the command typed; press Return to run it")
        }
    }
}
