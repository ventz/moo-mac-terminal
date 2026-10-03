//
//  MarkdownPreviewSession.swift
//  Moo
//
//  A markdown preview tab: one file, rendered by the bundled GitHub-style
//  renderer in a WKWebView, redrawn whenever the file changes on disk.
//
//  Owned by its WorkspaceTab, never by a view. The web view is created on
//  first display and kept until the tab closes, so switching tabs neither
//  reloads the page nor loses the reader's place.
//
//  Back and Forward (⌘[ / ⌘]) cover both ways a link can open: within the
//  tab, through its own history, and in a new tab, by returning to the
//  preview the link was clicked in.
//

import AppKit
import Observation
import SwiftUI
import WebKit

@Observable
@MainActor
final class MarkdownPreviewSession: NSObject, WebTabContent {
    enum State: Equatable {
        case loading
        case ready
        case missing
        case failed(String)
    }

    /// The file on screen. Changes when a link is followed within the tab.
    private(set) var fileURL: URL
    private(set) var state: State = .loading
    private(set) var lastRenderedAt: Date?

    let kind: WorkspaceTabKind = .markdown

    var displayTitle: String { fileURL.lastPathComponent }
    var currentDirectory: String? { fileURL.deletingLastPathComponent().path }

    @ObservationIgnored private let token: String
    /// The directory the first file was opened from. Every file the tab can
    /// reach lies under it: the scheme handler serves nothing else.
    @ObservationIgnored private let root: URL

    /// Files shown in this tab, oldest first, and where the reader was in
    /// each. Back and Forward move `historyIndex`; following a link drops
    /// everything after it, as a browser does.
    private var history: [HistoryEntry]
    private(set) var historyIndex = 0
    @ObservationIgnored private var pendingScrollY: Double?
    /// The restored position, kept until the page's diagrams are drawn
    @ObservationIgnored private var diagramScrollY: Double?

    /// The preview a link opened this tab from, and the last tab a link here
    /// opened: what Back and Forward return to once the tab's own history
    /// runs out. Weak, so a closed tab is not kept alive by a neighbor.
    @ObservationIgnored private(set) weak var opener: MarkdownPreviewSession?
    @ObservationIgnored private(set) weak var openedFromHere: MarkdownPreviewSession?
    /// Bumped when either link above changes, which observation cannot see.
    private var linkRevision = 0
    private(set) var isClosed = false
    @ObservationIgnored private var watcher: MarkdownFileWatcher?
    @ObservationIgnored private var container: MarkdownPreviewHostView?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: MarkdownPreviewBridge?
    @ObservationIgnored private var pendingMarkdown: String?
    /// The last text handed to the page, re-sent when the page comes back
    /// from a crash: without it the preview stayed blank until the next save.
    @ObservationIgnored private var lastMarkdown: String?
    @ObservationIgnored private var pageIsReady = false
    @ObservationIgnored private var appearanceObserver: NSObjectProtocol?

    init(fileURL: URL) {
        let fileURL = fileURL.standardizedFileURL
        self.fileURL = fileURL
        root = fileURL.deletingLastPathComponent()
        history = [HistoryEntry(fileURL: fileURL)]
        token = MarkdownDocumentRegistry.register(root: root)
        super.init()
    }

    // MARK: WebTabContent

    var hostedView: NSView {
        if let container { return container }
        let webView = makeWebView()
        let container = MarkdownPreviewHostView(
            webView: webView,
            toolbar: NSHostingView(rootView: MarkdownPreviewToolbar(session: self))
        )
        self.container = container
        self.webView = webView
        startWatching()
        startLoading(in: webView)
        return container
    }

    var hasHostedView: Bool { container != nil }

    func focus() {
        guard let webView, let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    func terminate() {
        isClosed = true
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        appearanceObserver = nil
        watcher?.stop()
        watcher = nil
        bridge?.session = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewBridge.name)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        container?.removeFromSuperview()
        container = nil
        MarkdownDocumentRegistry.unregister(token)
    }

    // MARK: Actions

    func reload() {
        watcher?.reload(force: true)
    }

    /// Through the router, not NSWorkspace directly: a `README.md` can be a
    /// symlink to something that runs, which is then only revealed.
    func openInEditor() {
        LinkRouter.openFile(fileURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: History

    var canGoBack: Bool {
        _ = linkRevision
        return historyIndex > 0 || opener?.isClosed == false
    }

    var canGoForward: Bool {
        _ = linkRevision
        return historyIndex < history.count - 1 || openedFromHere?.isClosed == false
    }

    func goBack() {
        if historyIndex > 0 {
            show(historyIndex: historyIndex - 1)
        } else if let opener, !opener.isClosed {
            MarkdownPreviewOpener.reveal(opener)
        }
    }

    func goForward() {
        if historyIndex < history.count - 1 {
            show(historyIndex: historyIndex + 1)
        } else if let openedFromHere, !openedFromHere.isClosed {
            MarkdownPreviewOpener.reveal(openedFromHere)
        }
    }

    /// Shows another markdown file in this tab, as a new history entry.
    /// Returns false for a file outside the tab's root, which this tab's
    /// scheme handler cannot serve.
    @discardableResult
    func navigate(to file: URL) -> Bool {
        let file = file.standardizedFileURL
        guard relativePath(of: file) != nil else { return false }
        guard file != fileURL else { return true }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(HistoryEntry(fileURL: file))
        show(historyIndex: history.count - 1)
        return true
    }

    /// Records that a link in `source` brought the reader here.
    func linked(from source: MarkdownPreviewSession) {
        guard source !== self else { return }
        opener = source
        linkRevision += 1
        source.openedFromHere = self
        source.linkRevision += 1
    }

    private func show(historyIndex index: Int) {
        let leaving = historyIndex
        historyIndex = index
        let entry = history[index]
        guard let webView, pageIsReady else {
            load(entry)
            return
        }
        // Remember where the reader was before the page goes away.
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let y = value as? Double, self.history.indices.contains(leaving) {
                    self.history[leaving].scrollY = y
                }
                guard self.historyIndex == index else { return }
                self.load(entry)
            }
        }
    }

    private func load(_ entry: HistoryEntry) {
        fileURL = entry.fileURL
        pendingScrollY = entry.scrollY > 0 ? entry.scrollY : nil
        diagramScrollY = nil
        watcher?.stop()
        watcher = nil
        pendingMarkdown = nil
        lastMarkdown = nil
        pageIsReady = false
        state = .loading
        // Not displayed yet: hostedView loads whatever file is current.
        guard let webView else { return }
        startWatching()
        startLoading(in: webView)
    }

    private func startLoading(in webView: WKWebView) {
        webView.load(URLRequest(url: MarkdownSchemeHandler.documentURL(
            token: token,
            relativePath: relativePath(of: fileURL) ?? fileURL.lastPathComponent
        )))
    }

    /// The file's path under the root, as the scheme handler addresses it.
    private func relativePath(of file: URL) -> String? {
        let rootPath = MarkdownSchemeHandler.canonicalPath(root.path)
        let filePath = MarkdownSchemeHandler.canonicalPath(file.path)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Previews render untrusted repository content: no cookies, no
        // shared storage, nothing kept between runs.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            MarkdownSchemeHandler(token: token, root: fileURL.deletingLastPathComponent()),
            forURLScheme: MarkdownSchemeHandler.scheme
        )
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let bridge = MarkdownPreviewBridge(session: self)
        configuration.userContentController.add(bridge, name: MarkdownPreviewBridge.name)
        self.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = UserDefaults.standard.bool(forKey: "webInspectorEnabled")
        }
        Self.applyAppearance(to: webView)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak webView] _ in
            MainActor.assumeIsolated {
                if let webView { Self.applyAppearance(to: webView) }
            }
        }
        return webView
    }

    /// The page's CSS and diagrams follow the web view's appearance. Pinned to
    /// light unless the user chose to follow the terminal theme, in which case
    /// it inherits the window's, which the theme sets.
    private static func applyAppearance(to webView: WKWebView) {
        let follows = UserDefaults.standard.bool(forKey: MarkdownPreviewDefaults.followsTerminalTheme)
        let appearance = follows ? nil : NSAppearance(named: .aqua)
        if webView.appearance?.name != appearance?.name {
            webView.appearance = appearance
        }
    }

    private func startWatching() {
        let file = fileURL
        let watcher = MarkdownFileWatcher(fileURL: file) { [weak self] event in
            // A late event from a file the tab has since navigated away from.
            guard let self, self.fileURL == file else { return }
            switch event {
            case .changed(let markdown):
                self.pendingMarkdown = markdown
                self.pushMarkdownIfReady()
            case .missing:
                self.state = .missing
            case .unreadable(let reason):
                self.state = .failed(reason)
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    private func pushMarkdownIfReady() {
        guard pageIsReady, let webView, let markdown = pendingMarkdown else { return }
        pendingMarkdown = nil
        lastMarkdown = markdown
        webView.callAsyncJavaScript(
            "await window.moo.render(markdown)",
            arguments: ["markdown": markdown],
            in: nil,
            in: .page
        ) { [weak self] result in
            if case .failure(let error) = result {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Messages from the page

    fileprivate func handle(message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            pageIsReady = true
            if pendingMarkdown == nil { pendingMarkdown = lastMarkdown }
            pushMarkdownIfReady()
        case "rendered":
            state = .ready
            lastRenderedAt = Date()
            // Only the render that restored a position re-applies it; a
            // later live reload keeps the reader's own scrolling.
            diagramScrollY = pendingScrollY
            if let y = pendingScrollY {
                pendingScrollY = nil
                webView?.evaluateJavaScript("window.scrollTo(0, \(y))")
            }
        case "diagramsDrawn":
            // Diagrams are drawn after "rendered" and change the page's
            // height, so a restored position is applied again.
            if let y = diagramScrollY {
                diagramScrollY = nil
                webView?.evaluateJavaScript("window.scrollTo(0, \(y))")
            }
        case "error":
            state = .failed(message["message"] as? String ?? "Unknown error")
        case "openLink":
            if let href = message["href"] as? String {
                // The page sends the click's modifiers; reading the keyboard
                // now could miss a Command already released.
                open(
                    link: href,
                    command: message["metaKey"] as? Bool ?? false,
                    option: message["altKey"] as? Bool ?? false
                )
            }
        case "copy":
            if let text = message["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "runCommand":
            if let text = message["text"] as? String {
                MarkdownPreviewOpener.run(command: text, from: self)
            }
        default:
            break
        }
    }

    /// A link inside the page. Another markdown file under the document's
    /// root opens in a new preview tab or in this one, per the setting, with
    /// ⌘-click doing the other; anything else goes through the router, with
    /// a same-root file opened by the system.
    private func open(link href: String, command: Bool, option: Bool) {
        guard let url = URL(string: href) else { return }
        if let file = MarkdownSchemeHandler.fileURL(for: url) {
            if LinkRouter.isMarkdown(file.path) {
                let newTab = MarkdownPreviewDefaults.linksOpenInNewTab(
                    inverted: command
                )
                if newTab || !navigate(to: file) {
                    MarkdownPreviewOpener.open(fileURL: file, linkedFrom: self)
                }
            } else {
                // Never launch something a repository shipped beside its README.
                LinkRouter.openFile(file)
            }
            return
        }
        LinkRouter.open(href, from: nil, forcesExternal: option)
    }
}

private struct HistoryEntry {
    let fileURL: URL
    var scrollY: Double = 0
}

// MARK: - Navigation policy

extension MarkdownPreviewSession: WKNavigationDelegate {
    /// Only the page's own load is allowed. Links are handled in script and
    /// never navigate; this is the backstop for anything that tries.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // The handler hands back a symlink-resolved path, so compare against
        // ours resolved the same way. A document under `~/proj -> git/...`
        // otherwise never matches, its own page is refused without an error,
        // and the tab sits on "Loading…" for good.
        let isOwnPage = url.scheme == MarkdownSchemeHandler.scheme
            && MarkdownSchemeHandler.fileURL(for: url)?.path
                == MarkdownSchemeHandler.canonicalPath(fileURL.path)
        if isOwnPage {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated {
                // The action carries the click's own modifiers.
                open(
                    link: url.absoluteString,
                    command: navigationAction.modifierFlags.contains(.command),
                    option: navigationAction.modifierFlags.contains(.option)
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .failed(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // One reload, not a loop: a page that keeps crashing stays crashed
        // and says so.
        pageIsReady = false
        state = .failed("The preview stopped unexpectedly.")
        webView.reload()
    }
}

/// The script-message receiver. WKUserContentController retains its
/// handlers, so this small object stands between it and the session to
/// avoid a cycle that would keep a closed tab alive.
private final class MarkdownPreviewBridge: NSObject, WKScriptMessageHandler {
    static let name = "moo"
    weak var session: MarkdownPreviewSession?

    init(session: MarkdownPreviewSession) {
        self.session = session
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the preview page itself may talk to the app: never a frame,
        // never a page from any other origin. The sanitizer admits no
        // iframes today; this is the cheap guard for the day it does.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == MarkdownSchemeHandler.scheme,
              let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            session?.handle(message: body)
        }
    }
}

// MARK: - Host view

/// Toolbar above, page below. Plain AppKit so it can live outside the
/// SwiftUI tree with the rest of the tab's state.
final class MarkdownPreviewHostView: NSView {
    private let toolbar: NSView
    private let webView: WKWebView
    private let toolbarHeight: CGFloat = 30

    init(webView: WKWebView, toolbar: NSView) {
        self.webView = webView
        self.toolbar = toolbar
        super.init(frame: .zero)
        addSubview(toolbar)
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - toolbarHeight)
    }
}

struct MarkdownPreviewToolbar: View {
    var session: MarkdownPreviewSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            Text(session.fileURL.path)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .help(session.fileURL.path)
            statusLabel
            Spacer()
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Back (⌘[)")
            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Forward (⌘])")
            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload (⌘R)")
            Button {
                session.openInEditor()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("Open in the default editor")
            Button {
                session.revealInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.state {
        case .loading:
            Text("Loading…").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .ready:
            EmptyView()
        case .missing:
            Label("File moved or deleted", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

enum MarkdownPreviewDefaults {
    /// Whether previews take the terminal theme's light or dark look. Off by
    /// default: a preview reads like a document, light with dark text.
    static let followsTerminalTheme = "markdownPreviewFollowsTerminalTheme"
    /// Whether a link to another markdown file opens a new preview tab (the
    /// default) or replaces the page in the tab it was clicked in.
    static let opensLinksInNewTab = "markdownPreviewOpensLinksInNewTab"

    static let registrationValues: [String: Any] = [
        opensLinksInNewTab: true
    ]

    /// The setting, flipped when the click carried ⌘.
    static func linksOpenInNewTab(inverted: Bool, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: opensLinksInNewTab) != inverted
    }
}
