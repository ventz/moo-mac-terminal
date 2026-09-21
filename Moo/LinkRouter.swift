//
//  LinkRouter.swift
//  Moo
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

enum LinkRoutingDefaults {
    /// Whether links open inside Moo when a tab kind can show them.
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

    /// The unbroken run of text around `column` in one terminal row, one
    /// string per cell. SwiftTerm's implicit detection follows Ghostty and
    /// only recognizes a path that has a slash, so a bare `README.md` printed
    /// by `ls` is never offered as a link; the terminal view falls back to
    /// this word and opens it only if it names an existing file.
    nonisolated static func word(inCells cells: [String], at column: Int) -> String? {
        wordSpan(inCells: cells, at: column)?.word
    }

    /// `word(inCells:at:)` with the cells it covers, so the view can
    /// underline it while Command is held.
    nonisolated static func wordSpan(inCells cells: [String], at column: Int) -> (word: String, columns: Range<Int>)? {
        func breaks(_ cell: String) -> Bool {
            // An empty cell is the second half of a wide character, not a gap.
            // An unwritten one reads as NUL — `ls` skips across gaps with tabs.
            !cell.isEmpty && cell.unicodeScalars.allSatisfy {
                $0 == "\0" || CharacterSet.whitespaces.contains($0) || wordDelimiters.contains($0)
            }
        }
        guard cells.indices.contains(column), !breaks(cells[column]) else { return nil }
        var start = column
        while start > cells.startIndex, !breaks(cells[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < cells.endIndex, !breaks(cells[end + 1]) { end += 1 }
        let trimmed: Set<String> = [".", ",", ";", ":"]
        while start <= end, trimmed.contains(cells[start]) { start += 1 }
        while end >= start, trimmed.contains(cells[end]) { end -= 1 }
        guard start <= end else { return nil }
        return (cells[start...end].joined(), start..<(end + 1))
    }

    private nonisolated static let wordDelimiters = CharacterSet(charactersIn: "\"'`()[]{}<>|")

    /// Splits a copied terminal row back into one string per cell. A wide
    /// character's trailing cell (width 0) becomes an empty string; whether
    /// the row text carries a character for that cell is read from its length.
    nonisolated static func cells(fromRowText text: String, cellWidths: [Int]) -> [String] {
        let characters = Array(text)
        let skipsTrailingHalves = characters.count != cellWidths.count
        var cells: [String] = []
        cells.reserveCapacity(cellWidths.count)
        var next = characters.startIndex
        for width in cellWidths {
            if width == 0 && skipsTrailingHalves {
                cells.append("")
                continue
            }
            cells.append(next < characters.endIndex ? String(characters[next]) : " ")
            next += 1
        }
        return cells
    }

    /// Turns detected text into an existing regular file path, or nil:
    /// tilde expansion, a trailing `:line[:column]`, and resolution against
    /// the terminal's directory.
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

    /// What handing a link to the system means. Terminal output is untrusted
    /// — a `cat`ed file or a remote host can print any URL — so only the web
    /// and mail open directly; other schemes launch arbitrary registered apps
    /// (`smb://` mounts a share, `x-man-page://` runs man) and need a yes.
    enum ExternalAction: Equatable {
        case openURL(URL)
        /// A local file or directory, through `openFile`'s executable check.
        case openFile(URL)
        case confirm(URL)
        case ignore
    }

    nonisolated static let directlyOpenedSchemes: Set<String> = ["http", "https", "mailto"]
    nonisolated static let refusedSchemes: Set<String> = ["javascript", "data", "vbscript"]

    /// - Parameter hasHandler: whether some app opens the URL. Without one,
    ///   `Makefile:12` (scheme "makefile") would ask to open with "No app".
    nonisolated static func externalAction(
        for link: String,
        workingDirectory: String?,
        fileManager: FileManager = .default,
        hasHandler: (URL) -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
    ) -> ExternalAction {
        if let path = resolvePath(link, workingDirectory: workingDirectory, fileManager: fileManager) {
            return .openFile(URL(fileURLWithPath: path))
        }
        // A scheme with a dot is almost always a file with a line number
        // ("README.md:12"), not a URL.
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), !scheme.contains(".") {
            if directlyOpenedSchemes.contains(scheme) { return .openURL(url) }
            if refusedSchemes.contains(scheme) { return .ignore }
            if scheme == "file" {
                return fileManager.fileExists(atPath: url.path) ? .openFile(url) : .ignore
            }
            return hasHandler(url) ? .confirm(url) : .ignore
        }
        // Directories and bundles: resolvePath takes regular files only.
        let expanded = NSString(string: link).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : workingDirectory.map { ($0 as NSString).appendingPathComponent(expanded) }
        if let absolute, fileManager.fileExists(atPath: absolute) {
            return .openFile(URL(fileURLWithPath: (absolute as NSString).standardizingPath))
        }
        return .ignore
    }

    private static func openExternally(_ link: String, workingDirectory: String?) {
        switch externalAction(for: link, workingDirectory: workingDirectory) {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openFile(let url):
            openFile(url)
        case .confirm(let url):
            if confirmOpening(url) { NSWorkspace.shared.open(url) }
        case .ignore:
            break
        }
    }

    private static func confirmOpening(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? "No app"
        // The URL came from terminal output: show it whole, as data.
        alert.informativeText = "\(url.absoluteString)\n\nOpens with: \(handler)"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Files that LaunchServices would *run* rather than show. A repository
    /// can ship any of these beside a README, and files from `git clone`
    /// carry no quarantine flag, so Gatekeeper would not step in. They are
    /// revealed in the Finder instead of opened; everything else opens in
    /// its default app as before.
    static let executableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "fish", "scpt", "scptd",
        "applescript", "workflow", "action", "terminal", "webloc", "inetloc",
        "shortcut", "pkg", "mpkg", "dmg", "iso", "jar", "py", "rb", "pl", "fileloc",
        // Not executable, but one click from changing the system: a
        // configuration profile goes straight to System Settings' installer
        // (certificates, proxies, MDM payloads), and the rest install code
        // that runs inside other processes.
        "mobileconfig", "prefpane", "saver", "plugin", "qlgenerator"
    ]

    nonisolated static func isExecutable(_ url: URL) -> Bool {
        if executableExtensions.contains(url.pathExtension.lowercased()) { return true }
        // A file that cannot be inspected cannot be shown to be safe. The path
        // came from untrusted text, so fail closed: revealing a file that
        // turns out to be harmless costs a click, opening one that was not
        // costs far more. (A missing file reveals to nothing, harmlessly.)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return true
        }
        // A bundle or a file with the execute bit set is also something that
        // runs when opened.
        if let permissions = attributes[FileAttributeKey.posixPermissions] as? Int,
           attributes[FileAttributeKey.type] as? FileAttributeType == .typeRegular,
           permissions & 0o111 != 0 {
            return true
        }
        return NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// Opens a local file from untrusted text (terminal output, a link in
    /// a preview): anything that would execute is only revealed.
    static func openFile(_ link: URL) {
        // Judge what actually opens: a `README` symlink to an extensionless
        // executable would otherwise pass as a plain file.
        let url = link.resolvingSymlinksInPath()
        if isExecutable(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
