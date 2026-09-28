//
//  FinderServices.swift
//  Moo
//
//  The Services menu entries declared under NSServices in Info.plist:
//  "New Moo Tab Here", "New Moo Window Here" and "New Moo Workspace Here".
//  Finder hands over the selected files and folders; a selected path in any
//  app's text arrives as plain text. A file opens in the folder holding it.
//
//  NSMessage in Info.plist names the selector: "openTabHere" is
//  openTabHere(_:userData:error:). Renaming a method silently removes its
//  menu entry, since AppKit only finds it by that name.
//

import AppKit

@MainActor
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    /// Installs the provider. Called at launch; AppKit delivers a service
    /// that launched the app only once this is set.
    func install() {
        NSApp.servicesProvider = self
    }

    @objc func openTabHere(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        run(pasteboard, error: error) { FinderServiceActions.openTab(in: $0) }
    }

    @objc func openWindowHere(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        run(pasteboard, error: error) { FinderServiceActions.openWindow(in: $0) }
    }

    @objc func openWorkspaceHere(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        run(pasteboard, error: error) { FinderServiceActions.openWorkspace(in: $0) }
    }

    private func run(
        _ pasteboard: NSPasteboard,
        error: AutoreleasingUnsafeMutablePointer<NSString?>,
        open: (String) -> Void
    ) {
        let directories = FinderServiceDirectories.resolve(
            fileURLs: pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? [],
            text: pasteboard.string(forType: .string)
        )
        guard !directories.isEmpty else {
            error.pointee = "Moo could not find a folder in the selection." as NSString
            return
        }
        for directory in directories {
            open(directory)
        }
    }
}

/// Turns what a service was handed into the directories to open in.
enum FinderServiceDirectories {
    /// More than this many folders is almost certainly a stray Select All,
    /// and each one starts a shell.
    static let maximumCount = 16

    /// Each selected folder, or the folder holding each selected file, in
    /// selection order and without repeats. Falls back to the text as a path
    /// when no file came along. Anything that does not exist is dropped.
    nonisolated static func resolve(
        fileURLs: [URL],
        text: String?,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = fileURLs.filter(\.isFileURL).map(\.path)
        if candidates.isEmpty, let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // One path only: a paragraph that happens to contain a slash is
            // not a request to open anything.
            if !trimmed.isEmpty, !trimmed.contains("\n") {
                let expanded = NSString(string: trimmed).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    candidates = [expanded]
                }
            }
        }

        var result: [String] = []
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue
                ? path
                : (path as NSString).deletingLastPathComponent
            let standardized = (directory as NSString).standardizingPath
            if !result.contains(standardized) {
                result.append(standardized)
            }
            if result.count == maximumCount { break }
        }
        return result
    }
}

/// What each service does with one directory.
@MainActor
enum FinderServiceActions {
    /// A tab in the frontmost window's workspace. With no window open this
    /// is a new window, the same as the Window service.
    static func openTab(in directory: String, runtime: ProjectRuntime = .shared) {
        guard let scope = targetScope(runtime: runtime) else {
            openWindow(in: directory, runtime: runtime)
            return
        }
        guard let session = scope.session else {
            // A window outside every workspace keeps native tabs.
            var spec = WindowOpener.inheritedTabSpec()
            spec.workingDirectory = directory
            WindowOpener.openTab(spec: spec, targetWindow: scope.window)
            return
        }
        session.addTab(directory: directory)
        runtime.invalidate()
        bringForward(scope.window)
    }

    /// A new window on a new workspace, so it never lands on top of one
    /// that already has tabs.
    static func openWindow(
        in directory: String,
        runtime: ProjectRuntime = .shared,
        store: ProjectStore = AppModel.shared.projects
    ) {
        guard let project = makeWorkspace(in: directory, runtime: runtime, store: store) else {
            WindowOpener.openWindow(spec: LaunchSpec(workingDirectory: directory))
            return
        }
        // A new window adopts the remembered workspace when no other window
        // shows it, which this one is not yet.
        UserDefaults.standard.set(
            project.id.uuidString,
            forKey: ProjectSidebarDefaults.selectedProjectID
        )
        guard let window = WindowOpener.openWindow(spec: LaunchSpec()) else { return }
        // A window reopening the last run's layout takes that instead; move
        // it to the new workspace once it has picked. The saved one stays in
        // the sidebar.
        DispatchQueue.main.async {
            guard let scope = runtime.scopes.first(where: { $0.window === window }),
                  scope.selectedProjectID != project.id else { return }
            runtime.select(projectID: project.id, in: scope)
        }
    }

    /// A new workspace in the frontmost window, with the sidebar shown so
    /// the switch is visible. With no window open this is a new window.
    static func openWorkspace(
        in directory: String,
        runtime: ProjectRuntime = .shared,
        store: ProjectStore = AppModel.shared.projects
    ) {
        guard let scope = targetScope(runtime: runtime), scope.session != nil else {
            openWindow(in: directory, runtime: runtime, store: store)
            return
        }
        guard let project = makeWorkspace(in: directory, runtime: runtime, store: store) else {
            return
        }
        runtime.setSidebarVisible(true, in: scope)
        runtime.select(projectID: project.id, in: scope)
        bringForward(scope.window)
    }

    /// An auto-named workspace whose first tab starts in the directory. It
    /// takes the directory's name, as any auto-named workspace does.
    private static func makeWorkspace(
        in directory: String,
        runtime: ProjectRuntime,
        store: ProjectStore
    ) -> Project? {
        guard let project = try? store.addAutoNamed() else { return nil }
        runtime.session(for: project.id).addTab(directory: directory)
        return project
    }

    /// The window a service acts on: Moo's frontmost terminal window. The
    /// service runs while Finder is active, when Moo has no key or main
    /// window, so this goes by stacking order rather than keyScope.
    private static func targetScope(runtime: ProjectRuntime) -> WindowScope? {
        for window in NSApp.orderedWindows where window.isVisible {
            if let scope = runtime.scope(for: window), !scope.isClosed {
                return scope
            }
        }
        return nil
    }

    private static func bringForward(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
