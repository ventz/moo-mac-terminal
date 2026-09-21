import AppKit
import Testing
@testable import Moo

/// The red button closes its window. Only cmd+W and File ▸ Close go through
/// the tab and project close policy, so the button can never close a tab, or
/// delete a project, when all that was asked was to close the window.
@MainActor
struct WindowCloseButtonTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func click(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    private func closeButtonCenter(in window: NSWindow) throws -> NSPoint {
        let button = try #require(window.standardWindowButton(.closeButton))
        let container = try #require(button.superview)
        return container.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
    }

    @Test func aClickOnTheRedButtonIsRecognized() throws {
        let window = makeWindow()
        let point = try closeButtonCenter(in: window)
        #expect(WindowCloseInterceptor.isCloseButtonClick(click(.leftMouseUp, at: point, in: window), in: window))
        #expect(WindowCloseInterceptor.isCloseButtonClick(click(.leftMouseDown, at: point, in: window), in: window))
    }

    @Test func otherEventsBehaveLikeCommandW() throws {
        let window = makeWindow()
        // No event at all: a close sent from code.
        #expect(!WindowCloseInterceptor.isCloseButtonClick(nil, in: window))
        // A click elsewhere in the window, as a menu choice would be.
        let inside = NSPoint(x: 200, y: 100)
        #expect(!WindowCloseInterceptor.isCloseButtonClick(click(.leftMouseUp, at: inside, in: window), in: window))
        // A key press, cmd+W.
        let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        )
        #expect(!WindowCloseInterceptor.isCloseButtonClick(key, in: window))
        // A click on another window's red button.
        let other = makeWindow()
        let point = try closeButtonCenter(in: other)
        #expect(!WindowCloseInterceptor.isCloseButtonClick(click(.leftMouseUp, at: point, in: other), in: window))
    }
}
