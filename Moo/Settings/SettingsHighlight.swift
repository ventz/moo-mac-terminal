//
//  SettingsHighlight.swift
//  Moo
//
//  Takes a search result to its setting: the page opens, scrolls to the
//  setting and outlines it for a moment, the way System Settings does.
//
//  Each setting a search entry names carries `.settingsAnchor(page, title)`
//  with the entry's own page and title. SettingsSearchTests fails when an
//  entry has no anchor, so a result never opens a page and leaves you
//  looking for it.
//

import SwiftUI

@MainActor
@Observable
final class SettingsHighlight {
    static let shared = SettingsHighlight()

    struct Request: Equatable {
        let anchorID: String
        /// A fresh token per click, so choosing the same result twice flashes
        /// it twice.
        let token = UUID()
        let date = Date()
    }

    private(set) var request: Request?
    /// Bumped when the requested setting's anchor appears, so the settings
    /// window scrolls to it once it exists rather than after a fixed delay.
    private(set) var scrollRequest = 0

    func reveal(_ anchorID: String) {
        request = Request(anchorID: anchorID)
    }

    /// Called by an anchor as it appears; asks for a scroll when it is the
    /// one a fresh request is waiting for.
    func anchorAppeared(_ anchorID: String) {
        guard isPending(anchorID), let token = request?.token, scrolledToken != token else { return }
        // Once per request: an anchor scrolled out and back in by the user
        // must not pull the page back to itself.
        scrolledToken = token
        scrollRequest += 1
    }

    @ObservationIgnored private var scrolledToken: UUID?

    /// A row that appears after the request (its page was still opening)
    /// flashes only if the request is recent; coming back to a page later
    /// must not flash an old result.
    func isPending(_ anchorID: String, now: Date = Date()) -> Bool {
        guard let request, request.anchorID == anchorID else { return false }
        return now.timeIntervalSince(request.date) < 2
    }
}

extension SettingsSearch.Entry {
    static func anchorID(_ destination: SettingsDestination, _ title: String) -> String {
        "\(destination.title)/\(title)"
    }
}

extension View {
    /// Marks the setting a search entry with this page and title points at.
    func settingsAnchor(_ destination: SettingsDestination, _ title: String) -> some View {
        modifier(SettingsAnchor(anchorID: SettingsSearch.Entry.anchorID(destination, title)))
    }
}

private struct SettingsAnchor: ViewModifier {
    let anchorID: String
    @State private var isFlashing = false
    /// The request this outline belongs to, so the fade-out scheduled for
    /// one click never cuts short the outline of a later click.
    @State private var flashToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .id(anchorID)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-5)
                    .opacity(isFlashing ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onChange(of: SettingsHighlight.shared.request) { _, request in
                guard let request else { return }
                if request.anchorID == anchorID {
                    flash(request.token)
                } else if isFlashing {
                    // Another result was chosen: let go of this one at once.
                    flashToken = nil
                    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) { isFlashing = false }
                }
            }
            .onAppear {
                if SettingsHighlight.shared.isPending(anchorID),
                   let token = SettingsHighlight.shared.request?.token {
                    SettingsHighlight.shared.anchorAppeared(anchorID)
                    if flashToken != token { flash(token) }
                }
            }
    }

    private func flash(_ token: UUID) {
        // Shown, held, then faded; Reduce Motion gets the outline without
        // the animation.
        flashToken = token
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isFlashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard flashToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.5)) { isFlashing = false }
        }
    }
}
