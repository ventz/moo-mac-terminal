//
//  DemoCapture.swift
//  Moo
//
//  Debug builds only: screenshots of the real app with nothing of the
//  user's in them. scripts/screenshots.sh seeds a scratch HOME (sample
//  projects, a ~/.z, a plain .zshrc) and launches Moo with MOO_CAPTURE=1;
//  this builds sample workspaces and tabs, opens the ⌘K palette on each
//  query, saves PNGs of its own window to MOO_CAPTURE_DIR and quits.
//
//  An app may capture its own windows without Screen Recording, which a
//  terminal running Claude Code does not have; the same approach as
//  Wombat's demo mode.
//

#if DEBUG
import AppKit
import SwiftTerm

@MainActor
enum DemoCapture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["MOO_CAPTURE"] == "1"
    }

    private static weak var appDelegate: AppDelegate?

    static func start(appDelegate: AppDelegate) {
        guard isRequested else { return }
        self.appDelegate = appDelegate
        Task { @MainActor in await run() }
    }

    private static var home: String { NSHomeDirectory() }
    private static func path(_ relative: String) -> String { home + "/" + relative }

    private static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["MOO_CAPTURE_DIR"] ?? path("captures")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // The first window can take a while (a fresh home, first launch).
        var found: NSWindow?
        // Moo opens its first window when it becomes active, which a launch
        // in the background never does by itself.
        // macOS may refuse to activate an app launched while someone works
        // in another one; then run the same startup-window path directly.
        for attempt in 0..<40 {
            NSApp.activate(ignoringOtherApps: true)
            found = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            if found != nil { break }
            if attempt == 6, let delegate = appDelegate {
                delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(1))

        let runtime = ProjectRuntime.shared
        let store = AppModel.shared.projects
        guard let window = found else {
            return finish("no window")
        }
        let scope = runtime.keyScope
        window.setContentSize(NSSize(width: 940, height: 600))
        window.center()

        // The workspace the first window made for itself goes once ours exist.
        let startup = store.projects.map(\.id)
        let port = environment["MOO_CAPTURE_PORT"] ?? "48173"

        // Workspaces, oldest-used first, so the list reads newest first.
        func project(_ name: String) -> Project? {
            store.projects.first { $0.name == name } ?? (try? store.add(name: name))
        }
        guard let shop = project("shop"), let blog = project("blog"),
              let infra = project("infra"), let docs = project("handbook") else {
            return finish("could not create workspaces")
        }
        _ = docs  // listed, never opened

        // Each workspace's tabs open in their own folders; the tab a
        // workspace starts with (in ~) is closed once they exist.
        func open(_ project: Project, _ build: (WorkspaceSession) async -> Void) async {
            runtime.select(projectID: project.id, in: scope)
            let session = runtime.session(for: project.id)
            let first = session.tabs.first
            await build(session)
            if let first, session.tabs.count > 1 { session.close(first) }
            runtime.invalidate()
        }

        await open(infra) { session in
            await shell(session, "code/infra")
        }
        await open(blog) { session in
            await shell(session, "code/blog", run: "vim posts/hello-world.md")
            await shell(session, "code/blog")
        }
        for id in startup {
            runtime.discardSession(for: id)
            try? store.delete(id)
        }

        // shop: a dev server, an editor split beside a shell, the API's
        // logs, a README preview, the site in a browser tab, and a shell.
        await open(shop) { session in
            await shell(session, "code/shop-web", run: "python3 -m http.server \(port)")
            if let editor = await shell(session, "code/shop-web/src", run: "vim checkout.ts"),
               let left = editor.controllers.first {
                editor.panes?.split(left, orientation: .vertical)
                runtime.invalidate()
                if let right = editor.controllers.last, right !== left {
                    await waitForPrompt(right)
                    type(right, "git log --oneline -4")
                }
                // The tab is titled after its focused split: the editor.
                editor.panes?.markFocused(left)
            }
            await shell(session, "code/shop-api", run: "tail -f logs/api.log")
            session.addTab(web: MarkdownPreviewSession(fileURL: URL(fileURLWithPath: path("code/shop-web/README.md"))))
            // Only the sample page: anything else answering on this port is
            // the user's own, and must never appear in a screenshot.
            let site = URL(string: "http://127.0.0.1:\(port)/")!
            var answered = false
            for _ in 0..<20 where !answered {
                if let (data, _) = try? await URLSession.shared.data(from: site) {
                    answered = String(decoding: data, as: UTF8.self).contains("<title>Shop · localhost</title>")
                    if !answered { break }
                } else {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if answered {
                session.addTab(web: BrowserSession(url: site))
            } else {
                print("capture: the sample site did not answer on \(port); no browser tab")
            }
            runtime.invalidate()
            try? await Task.sleep(for: .milliseconds(1500))
            await shell(session, "code/shop-web", run: "ls")
        }
        try? await Task.sleep(for: .milliseconds(1200))

        for (query, name) in [("shop", "moo-palette-tabs"), ("z docs", "moo-palette-dirs")] {
            scope.paletteInitialQuery = query
            if scope.isPaletteVisible {
                scope.paletteQueryRequest += 1
            } else {
                scope.isPaletteVisible = true
            }
            try? await Task.sleep(for: .milliseconds(1500))
            await saveActive(window, "\(directory)/\(name).png")
        }
        scope.isPaletteVisible = false
        finish("captured to \(directory)")
    }

    /// A new terminal tab in `relative` (under the scratch HOME), running
    /// `command` once its shell is at a prompt.
    @discardableResult
    private static func shell(_ session: WorkspaceSession, _ relative: String, run command: String? = nil) async -> WorkspaceTab? {
        let tab = session.addTab(directory: path(relative))
        ProjectRuntime.shared.invalidate()
        guard let controller = tab.controllers.first else { return tab }
        await waitForPrompt(controller)
        if let command { type(controller, "clear; " + command) } else { type(controller, "clear") }
        try? await Task.sleep(for: .milliseconds(400))
        return tab
    }

    /// Typed text sent before the shell has drawn its first prompt is lost.
    private static func waitForPrompt(_ controller: TerminalSessionController) async {
        for _ in 0..<40 {
            if controller.currentWorkingDirectory != nil, controller.shellOwnsTerminal { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func type(_ controller: TerminalSessionController?, _ line: String) {
        controller?.terminal?.send(txt: line + "\r")
    }

    /// Ends every shell (the dev server, vim, tail) and exits: quitting
    /// normally would stop to ask about the running programs.
    private static func finish(_ message: String) {
        print("capture: \(message)")
        for project in AppModel.shared.projects.projects {
            ProjectRuntime.shared.discardSession(for: project.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    /// Only once the window is key in the active app: an inactive window
    /// draws gray traffic lights.
    private static func saveActive(_ window: NSWindow, _ path: String) async {
        for attempt in 0..<20 {
            if NSApp.isActive && window.isKeyWindow && window.isMainWindow { break }
            if attempt == 19 { print("capture: \(path) may be inactive") }
            NSApp.activate()
            window.level = .floating
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            try? await Task.sleep(for: .milliseconds(300))
        }
        save(window, path)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is unavailable to Swift on current SDKs; it
    /// still works for the app's own windows, so look it up at run time.
    private static func save(_ window: NSWindow, _ path: String) {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return print("capture: no CGWindowListCreateImage")
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow; kCGWindowImageDefault keeps the shadow, like the other shots.
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue() else {
            return print("capture: failed for \(path)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("capture: wrote \(path) (\(image.width)x\(image.height))")
        } catch {
            print("capture: could not write \(path): \(error.localizedDescription)")
        }
    }
}
#endif
