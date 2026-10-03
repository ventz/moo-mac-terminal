//
//  UpdateBadge.swift
//  Moo
//
//  A purple dot at the trailing end of every window's titlebar while a newer
//  version is waiting. Clicking it says which version, and opens Sparkle's
//  update window from there. Hidden when there is nothing to install.
//

import AppKit
import Combine
import SwiftUI

/// Hosts the dot as a titlebar accessory, so it sits in the native titlebar
/// (and its drag region) rather than over the window's content.
final class UpdateBadgeAccessory: NSTitlebarAccessoryViewController {
    private var subscription: AnyCancellable?

    /// Adds the accessory once; SwiftUI configures a window many times.
    static func install(in window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0 is UpdateBadgeAccessory })
        else { return }
        window.addTitlebarAccessoryViewController(UpdateBadgeAccessory())
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        let host = NSHostingView(rootView: UpdateBadgeView(model: .shared))
        host.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
        view = host
        isHidden = UpdaterModel.shared.availableUpdate == nil
        subscription = UpdaterModel.shared.$availableUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.isHidden = update == nil
            }
    }
}

struct UpdateBadgeView: View {
    @ObservedObject var model: UpdaterModel
    @State private var isShowingDetails = false

    var body: some View {
        if let update = model.availableUpdate {
            Button {
                isShowingDetails.toggle()
            } label: {
                Circle()
                    .fill(Color(nsColor: .systemPurple))
                    // The ring keeps the dot visible on theme-colored title
                    // bars close to purple (Fairyfloss, Ocean, Red Sands).
                    .overlay(Circle().strokeBorder(Color(nsColor: .labelColor).opacity(0.5), lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Moo \(update.version) is available")
            .accessibilityLabel("Update available: Moo \(update.version)")
            .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                UpdateDetails(update: update, canInstall: model.updatesEnabled) {
                    isShowingDetails = false
                    model.checkForUpdates()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UpdateDetails: View {
    let update: AvailableUpdate
    let canInstall: Bool
    let showUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Update")
                .font(.headline)
            Text("Moo \(update.version) is available. You have \(AvailableUpdate.installedVersion).")
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let date = update.date {
                Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Show Update…", action: showUpdate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
