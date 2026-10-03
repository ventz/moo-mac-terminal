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

    /// The title is centered on the window, not on the space after the
    /// traffic lights; a title too long to center slides over instead.
    @Test func titleIsCenteredOnTheWindow() throws {
        let window = makeWindow()
        defer { window.close() }
        window.title = "short"
        WindowTitleAccessory.install(in: window)
        let accessory = try #require(window.titlebarAccessoryViewControllers.first { $0 is WindowTitleAccessory })
        let label = try #require(titleLabel(in: window))
        accessory.view.layoutSubtreeIfNeeded()
        accessory.view.layoutSubtreeIfNeeded()
        let labelCenter = label.convert(NSPoint(x: label.bounds.midX, y: 0), to: nil).x
        #expect(abs(labelCenter - window.frame.width / 2) < 2)

        window.title = String(repeating: "long title ", count: 40)
        accessory.view.layoutSubtreeIfNeeded()
        let leading = label.convert(NSPoint.zero, to: nil).x
        #expect(leading >= accessory.view.convert(NSPoint.zero, to: nil).x)
    }
}
