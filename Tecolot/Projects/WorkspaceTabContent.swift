//
//  WorkspaceTabContent.swift
//  Tecolot
//
//  What a workspace tab can hold. A tab has always been a terminal split
//  tree; this introduces a second family — web content hosted in an NSView
//  the tab owns — so a markdown preview or a browser can sit in the same
//  strip as the terminals without being a terminal.
//
//  Web content is deliberately behind a protocol rather than an enum of
//  concrete types: the tab model, the strip and the close policy need to
//  know a title, a directory and how to show and end the thing, and nothing
//  else. The concrete sessions live in their own features.
//

import AppKit
import Foundation

/// The family a tab belongs to, for the strip's icon and command enabling.
enum WorkspaceTabKind: Equatable, Sendable {
    case terminal
    case markdown
    case browser

    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .markdown: return "doc.richtext"
        case .browser: return "globe"
        }
    }
}

/// Non-terminal tab content. Implemented by the markdown preview and the
/// browser sessions; owned by the tab, outside the SwiftUI view tree, so a
/// tab that is not on screen keeps its state exactly as a terminal keeps its
/// shell.
@MainActor
protocol WebTabContent: AnyObject {
    var kind: WorkspaceTabKind { get }
    /// What the tab strip shows.
    var displayTitle: String { get }
    /// The directory this content relates to, if any — a preview's file
    /// directory, say — so the sidebar can keep listing where a project is.
    var currentDirectory: String? { get }
    /// The view to put on screen. Created lazily on first request and kept
    /// for the life of the content, so switching tabs never rebuilds it.
    var hostedView: NSView { get }
    /// True once `hostedView` has been created. Lets callers avoid creating
    /// a web view just to tear it down.
    var hasHostedView: Bool { get }
    /// Asks for keyboard focus after the hosted view is in a window.
    func focus()
    /// The tab is going away for good: release the hosted view and stop any
    /// watchers. Never called for a mere tab switch.
    func terminate()
}

enum WorkspaceTabContent {
    case terminal(TerminalPaneWorkspace)
    case web(any WebTabContent)

    var kind: WorkspaceTabKind {
        switch self {
        case .terminal: return .terminal
        case .web(let content): return content.kind
        }
    }
}
