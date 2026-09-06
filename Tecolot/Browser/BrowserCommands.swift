//
//  BrowserCommands.swift
//  Tecolot
//
//  How browser tabs come to exist — a menu command, a link clicked in the
//  terminal, a page opening a popup — and the menu items that act on one.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
enum BrowserOpener {
    /// Hooks the feature into the link router. Called once at launch.
    static func install() {
        LinkRouter.openBrowser = { url, _ in
            open(url: url)
        }
    }

    /// Opens a browser tab in the selected workspace. Returns false when
    /// there is no workspace to put a tab in, so the caller can fall back to
    /// the system browser.
    @discardableResult
    static func open(url: URL?) -> Bool {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession else { return false }
        session.addTab(web: BrowserSession(url: url))
        runtime.invalidate()
        return true
    }

    /// ⇧⌘B: a tab showing the address on the clipboard when there is one,
    /// otherwise an empty tab with the address field ready.
    static func openNew() {
        if let text = NSPasteboard.general.string(forType: .string),
           let url = clipboardURL(text) {
            open(url: url)
            return
        }
        open(url: nil)
    }

    nonisolated static func clipboardURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !trimmed.contains("\n"), lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            return nil
        }
        return URL(string: trimmed)
    }

    /// A page asked for a new window. The tab is created now and its web
    /// view handed back, built from WebKit's configuration so the opener
    /// relationship holds.
    static func openPopup(configuration: WKWebViewConfiguration) -> WKWebView? {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession else { return nil }
        let browser = BrowserSession(popupConfiguration: configuration)
        session.addTab(web: browser)
        runtime.invalidate()
        return browser.webViewForPopup
    }

    static var selectedBrowser: BrowserSession? {
        ProjectRuntime.shared.selectedSession?.selectedTab?.web as? BrowserSession
    }
}

struct BrowserCommands: Commands {
    @State private var runtime = ProjectRuntime.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Browser Tab") {
                BrowserOpener.openNew()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Open Location…") {
                BrowserOpener.selectedBrowser?.requestAddressFocus()
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(selectedBrowser == nil)

            Button("Back") {
                BrowserOpener.selectedBrowser?.goBack()
            }
            .disabled(selectedBrowser?.canGoBack != true)

            Button("Forward") {
                BrowserOpener.selectedBrowser?.goForward()
            }
            .disabled(selectedBrowser?.canGoForward != true)

            Button("Open Page in Default Browser") {
                BrowserOpener.selectedBrowser?.openInDefaultBrowser()
            }
            .disabled(selectedBrowser?.url == nil)
        }
    }

    /// Read through the observed runtime so the items enable and disable
    /// as the selected tab changes.
    private var selectedBrowser: BrowserSession? {
        _ = runtime.revision
        return BrowserOpener.selectedBrowser
    }
}
