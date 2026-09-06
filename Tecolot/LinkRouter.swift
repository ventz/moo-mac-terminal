//
//  LinkRouter.swift
//  Tecolot
//
//  Decides where a link clicked in a terminal goes. SwiftTerm hands over the
//  raw text — an explicit URL, or an implicit path it detected in the output
//  — and until now every one of them went to NSWorkspace. With web tabs in
//  the strip, a markdown file can open as a preview beside the shell and a
//  web address as a browser tab, so the user never leaves the window.
//
//  Classification is pure and tested. Acting on a destination goes through
//  handlers the preview and browser features register when they exist; a
//  destination with no handler falls back to the system, exactly as before.
//

import AppKit
import Foundation
import SwiftTerm

enum LinkRoutingDefaults {
    /// Whether links open inside Tecolot when a tab kind can show them.
    static let opensLinksInApp = "linksOpenInApp"

    static let registrationValues: [String: Any] = [
        opensLinksInApp: true
    ]

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: opensLinksInApp)
    }
}

enum LinkDestination: Equatable {
    /// Whatever the system would do: the default browser, the default editor,
    /// Finder for a directory.
    case external
    /// A local markdown file, for a preview tab.
    case markdownPreview(URL)
    /// An http(s) address, for a browser tab.
    case browser(URL)
}

@MainActor
enum LinkRouter {
    /// Registered by the markdown preview feature. Returns false when it could
    /// not take the link, in which case it opens externally.
    static var openMarkdownPreview: ((URL, TerminalSessionController?) -> Bool)?
    /// Registered by the browser feature, likewise.
    static var openBrowser: ((URL, TerminalSessionController?) -> Bool)?

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// Entry point for a click in a terminal.
    ///
    /// - Parameter forcesExternal: true when the click carried the option
    ///   key, which always means "the way it used to work".
    static func open(
        _ link: String,
        from controller: TerminalSessionController?,
        forcesExternal: Bool = NSEvent.modifierFlags.contains(.option)
    ) {
        let destination = forcesExternal || !LinkRoutingDefaults.isEnabled
            ? .external
            : classify(link, workingDirectory: controller?.currentWorkingDirectory)

        switch destination {
        case .markdownPreview(let url):
            if openMarkdownPreview?(url, controller) == true { return }
        case .browser(let url):
            if openBrowser?(url, controller) == true { return }
        case .external:
            break
        }
        openExternally(link, workingDirectory: controller?.currentWorkingDirectory)
    }

    /// Works out what a link is without touching any UI. Relative paths are
    /// resolved against the terminal's own directory (OSC 7), which is where
    /// the user was looking when the path was printed — not the app's.
    nonisolated static func classify(
        _ link: String,
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> LinkDestination {
        // Only real schemes count. `URL(string:)` happily parses
        // "README.md:12:3" as scheme "README.md", so a prefix check is the
        // honest test here.
        let lowered = link.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: link).map(LinkDestination.browser) ?? .external
        }
        if lowered.hasPrefix("file://") {
            guard let url = URL(string: link) else { return .external }
            return isMarkdown(url.path) ? .markdownPreview(url) : .external
        }

        guard let path = resolvePath(link, workingDirectory: workingDirectory, fileManager: fileManager),
              isMarkdown(path) else {
            return .external
        }
        return .markdownPreview(URL(fileURLWithPath: path))
    }

    nonisolated static func isMarkdown(_ path: String) -> Bool {
        markdownExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Turns detected text into an existing file path, or nil. Mirrors what
    /// SwiftTerm's default handler accepts — tilde expansion and a trailing
    /// `:line[:column]` — plus resolution against the terminal's directory.
    nonisolated static func resolvePath(
        _ link: String,
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> String? {
        let expanded = NSString(string: link).expandingTildeInPath
        var candidates = [expanded]
        if let range = expanded.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
            candidates.append(String(expanded[..<range.lowerBound]))
        }
        for candidate in candidates where !candidate.isEmpty {
            let absolute: String
            if candidate.hasPrefix("/") {
                absolute = candidate
            } else if let workingDirectory {
                absolute = (workingDirectory as NSString).appendingPathComponent(candidate)
            } else {
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: absolute, isDirectory: &isDirectory), !isDirectory.boolValue {
                return (absolute as NSString).standardizingPath
            }
        }
        return nil
    }

    /// The pre-existing behavior, with one improvement: a relative path is
    /// resolved against the terminal's directory before SwiftTerm tries the
    /// app's, which is what made `README.md` printed by `ls` open at all.
    private static func openExternally(_ link: String, workingDirectory: String?) {
        if let path = resolvePath(link, workingDirectory: workingDirectory) {
            openFile(URL(fileURLWithPath: path))
            return
        }
        TerminalView.openDefaultLink(link)
    }

    /// Files that LaunchServices would *run* rather than show. A repository
    /// can ship any of these beside a README, and files from `git clone`
    /// carry no quarantine flag, so Gatekeeper would not step in. They are
    /// revealed in the Finder instead of opened; everything else opens in
    /// its default app as before.
    static let executableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "fish", "scpt", "scptd",
        "applescript", "workflow", "action", "terminal", "webloc", "inetloc",
        "shortcut", "pkg", "mpkg", "dmg", "iso", "jar", "py", "rb", "pl"
    ]

    nonisolated static func isExecutable(_ url: URL) -> Bool {
        if executableExtensions.contains(url.pathExtension.lowercased()) { return true }
        // A bundle or a file with the execute bit set is also something that
        // runs when opened.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[FileAttributeKey.posixPermissions] as? Int,
           attributes[FileAttributeKey.type] as? FileAttributeType == .typeRegular,
           permissions & 0o111 != 0 {
            return true
        }
        return NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// Opens a local file from untrusted text (terminal output, a link in
    /// a preview): anything that would execute is only revealed.
    static func openFile(_ url: URL) {
        if isExecutable(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
