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

    let fileURL: URL
    private(set) var state: State = .loading
    private(set) var lastRenderedAt: Date?

    let kind: WorkspaceTabKind = .markdown

    var displayTitle: String { fileURL.lastPathComponent }
    var currentDirectory: String? { fileURL.deletingLastPathComponent().path }

    @ObservationIgnored private let token: String
    @ObservationIgnored private var watcher: MarkdownFileWatcher?
    @ObservationIgnored private var container: MarkdownPreviewHostView?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: MarkdownPreviewBridge?
    @ObservationIgnored private var pendingMarkdown: String?
    /// The last text handed to the page, re-sent when the page comes back
    /// from a crash: without it the preview stayed blank until the next save.
    @ObservationIgnored private var lastMarkdown: String?
    @ObservationIgnored private var pageIsReady = false

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        token = MarkdownDocumentRegistry.register(root: self.fileURL.deletingLastPathComponent())
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
        webView.load(URLRequest(url: MarkdownSchemeHandler.documentURL(
            token: token,
            relativePath: fileURL.lastPathComponent
        )))
        return container
    }

    var hasHostedView: Bool { container != nil }

    func focus() {
        guard let webView, let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    func terminate() {
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

    func openInEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
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
        return webView
    }

    private func startWatching() {
        let watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] event in
            guard let self else { return }
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
            "await window.tecolot.render(markdown)",
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
        case "error":
            state = .failed(message["message"] as? String ?? "Unknown error")
        case "openLink":
            if let href = message["href"] as? String {
                open(link: href)
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
    /// root becomes a preview tab; anything else goes through the router,
    /// with a same-root file opened by the system.
    private func open(link href: String) {
        guard let url = URL(string: href) else { return }
        if let file = MarkdownSchemeHandler.fileURL(for: url) {
            if LinkRouter.isMarkdown(file.path) {
                _ = MarkdownPreviewOpener.open(fileURL: file, from: nil)
            } else {
                // Never launch something a repository shipped beside its README.
                LinkRouter.openFile(file)
            }
            return
        }
        LinkRouter.open(href, from: nil, forcesExternal: NSEvent.modifierFlags.contains(.option))
    }
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
        let isOwnPage = url.scheme == MarkdownSchemeHandler.scheme
            && MarkdownSchemeHandler.fileURL(for: url) == fileURL
        if isOwnPage {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated {
                open(link: url.absoluteString)
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
    static let name = "tecolot"
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
