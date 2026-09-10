//
//  WebTabContainer.swift
//  Moo
//
//  Puts a web tab's hosted view on screen. The counterpart of
//  TerminalPaneContainer for non-terminal tabs, and built on the same rule:
//  the representable is never re-identified, so switching tabs hands the one
//  host a different child rather than rebuilding anything. The hosted view
//  belongs to the tab's content and survives being detached; a tab that is
//  not on screen keeps its page exactly as a terminal keeps its shell.
//

import AppKit
import SwiftUI

struct WebTabContainer: NSViewRepresentable {
    /// The content to show, or nil while a terminal tab is selected. Passing
    /// nil detaches rather than destroying, so the representable can stay
    /// mounted beside the terminal host at all times.
    let content: (any WebTabContent)?

    func makeNSView(context: Context) -> WebTabHostView {
        let view = WebTabHostView()
        view.show(content)
        return view
    }

    func updateNSView(_ nsView: WebTabHostView, context: Context) {
        nsView.show(content)
    }

    // Detach only. Dismantling means the host left the screen, not that the
    // page is done; the content still owns its view.
    static func dismantleNSView(_ nsView: WebTabHostView, coordinator: ()) {
        nsView.show(nil)
    }
}

final class WebTabHostView: NSView {
    private(set) weak var content: (any WebTabContent)?

    /// Swaps the single child for the content's view. A no-op when the same
    /// content is already showing, so SwiftUI updates never flicker the page.
    func show(_ newContent: (any WebTabContent)?) {
        if let newContent, let current = content, current === newContent,
           subviews.first === newContent.hostedView {
            return
        }
        subviews.forEach { $0.removeFromSuperview() }
        content = newContent
        guard let newContent else { return }
        let hosted = newContent.hostedView
        hosted.frame = bounds
        hosted.autoresizingMask = [.width, .height]
        addSubview(hosted)
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}
