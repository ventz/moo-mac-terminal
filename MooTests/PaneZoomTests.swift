import AppKit
import Testing
@testable import Moo

@MainActor
final class PaneZoomTests {
    private func workspaceWithTwoPanes() -> (TerminalPaneWorkspace, TerminalSessionController, TerminalSessionController) {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = workspace.controllers[0]
        workspace.split(first, orientation: .vertical)
        return (workspace, first, workspace.controllers[1])
    }

    @Test func singlePaneCannotZoom() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        workspace.toggleZoom()
        #expect(!workspace.isZoomed)
        #expect(workspace.displayedRoot === workspace.root)
    }

    @Test func zoomShowsOnlyTheFocusedPaneAndKeepsTheOthers() {
        let (workspace, _, second) = workspaceWithTwoPanes()
        let revision = workspace.revision
        workspace.toggleZoom()
        #expect(workspace.zoomedControllerID == second.id)
        #expect(workspace.revision == revision + 1)
        guard case .terminal(let shown) = workspace.displayedRoot.content else {
            Issue.record("zoomed root should be a single terminal")
            return
        }
        #expect(shown === second)
        #expect(workspace.paneCount == 2)

        workspace.toggleZoom()
        #expect(!workspace.isZoomed)
        #expect(workspace.displayedRoot === workspace.root)
    }

    @Test func zoomingANestedPaneShowsJustThatLeaf() {
        let (workspace, first, second) = workspaceWithTwoPanes()
        workspace.split(first, orientation: .horizontal)
        let nested = workspace.controllers.first { $0 !== first && $0 !== second }!
        workspace.markFocused(nested)
        workspace.toggleZoom()
        guard case .terminal(let shown) = workspace.displayedRoot.content else {
            Issue.record("zoomed root should be a single terminal")
            return
        }
        #expect(shown === nested)
        #expect(workspace.paneCount == 3)
        // Focusing the pane that is already zoomed keeps the zoom.
        workspace.markFocused(nested)
        #expect(workspace.isZoomed)
    }

    @Test func dividersSurviveAZoom() {
        let (workspace, _, _) = workspaceWithTwoPanes()
        let host = TerminalPaneHostView(workspace: workspace, document: TerminalDocument())
        // Split views only honor divider positions once they are in a window.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.synchronize(workspace: workspace, revision: workspace.revision, document: TerminalDocument())
        host.layoutSubtreeIfNeeded()
        guard let split = host.subviews.first as? NSSplitView else {
            Issue.record("two panes should show a split view")
            return
        }
        split.setPosition(200, ofDividerAt: 0)
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        #expect(abs((split.arrangedSubviews.first?.frame.width ?? 0) - 200) <= 1,
                "precondition: the divider moved before zooming")

        workspace.toggleZoom()
        host.showCurrentRevision()
        workspace.toggleZoom()
        host.showCurrentRevision()

        let restored = host.subviews.first as? NSSplitView
        #expect(abs((restored?.arrangedSubviews.first?.frame.width ?? 0) - 200) <= 1)
    }

    @Test func splittingOrClosingEndsTheZoom() {
        let (workspace, first, second) = workspaceWithTwoPanes()
        workspace.toggleZoom()
        workspace.split(second, orientation: .horizontal)
        #expect(!workspace.isZoomed)

        workspace.toggleZoom()
        workspace.close(first)
        #expect(!workspace.isZoomed)
    }

    @Test func focusingAnotherPaneEndsTheZoom() {
        let (workspace, first, _) = workspaceWithTwoPanes()
        workspace.toggleZoom()
        workspace.markFocused(first)
        #expect(!workspace.isZoomed)

        workspace.toggleZoom()
        workspace.selectNextSplit()
        #expect(!workspace.isZoomed)
    }
}
