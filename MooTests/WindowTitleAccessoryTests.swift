import AppKit
import Testing
@testable import Moo

@MainActor
struct WindowTitleAccessoryTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func titleLabel(in window: NSWindow) -> NSTextField? {
        window.titlebarAccessoryViewControllers
            .first { $0 is WindowTitleAccessory }?
            .view.subviews.compactMap { $0 as? NSTextField }.first
    }

    /// The system title, which AppKit turns into a rename/move control for
    /// document windows, is hidden; the label shows the same text instead.
    @Test func replacesTheSystemTitleWithAPlainLabel() throws {
        let window = makeWindow()
        defer { window.close() }
        window.title = "~/code — zsh"
        WindowTitleAccessory.install(in: window)

        #expect(window.titleVisibility == .hidden)
        #expect(titleLabel(in: window)?.stringValue == "~/code — zsh")
        window.title = "vim"
        #expect(titleLabel(in: window)?.stringValue == "vim")
    }

    @Test func installsOnce() {
        let window = makeWindow()
        defer { window.close() }
        WindowTitleAccessory.install(in: window)
        WindowTitleAccessory.install(in: window)
        #expect(window.titlebarAccessoryViewControllers.filter { $0 is WindowTitleAccessory }.count == 1)
    }

    /// Clicks pass through the label to the titlebar, so the title area
    /// still drags the window.
    @Test func titleIsNotClickable() throws {
        let window = makeWindow()
        defer { window.close() }
        WindowTitleAccessory.install(in: window)
        let view = try #require(window.titlebarAccessoryViewControllers.first { $0 is WindowTitleAccessory }?.view)
        #expect(view.hitTest(NSPoint(x: 20, y: 10)) == nil)
        #expect(view.mouseDownCanMoveWindow)
    }

    /// The title sits at the leading edge, after the traffic lights, not
    /// centered; a long title truncates instead of running past the edge.
    @Test func titleIsLeftAligned() throws {
        let window = makeWindow()
        defer { window.close() }
        window.title = "short"
        WindowTitleAccessory.install(in: window)
        let accessory = try #require(window.titlebarAccessoryViewControllers.first { $0 is WindowTitleAccessory })
        let label = try #require(titleLabel(in: window))
        accessory.view.layoutSubtreeIfNeeded()
        // Auto Layout places the alignment rect; a text field's frame sits
        // 2 pt outside it.
        var placed = label.alignmentRect(forFrame: label.frame)
        #expect(abs(placed.minX - 6) < 1)
        #expect(placed.midX < accessory.view.bounds.midX)

        window.title = String(repeating: "long title ", count: 40)
        accessory.view.layoutSubtreeIfNeeded()
        placed = label.alignmentRect(forFrame: label.frame)
        #expect(placed.maxX <= accessory.view.bounds.maxX + 0.5)
    }
}
