//
//  BrowserSession.swift
//  Moo
//
//  A browser tab: a WKWebView with an address bar, kept deliberately small.
//  It exists for the things a terminal user looks at beside a shell — a
//  localhost dev server, a docs page, a pull request — and offers "Open in
//  Default Browser" for everything else. It is a companion, not a browser.
//
//  Owned by its WorkspaceTab, outside the view tree, so a tab that is not
//  on screen keeps its page, history and scroll position.
//
//  Everything WebKit silently drops without a delegate is implemented here:
//  alert/confirm/prompt (otherwise confirm() returns false with no panel),
//  window.open (otherwise cancelled), HTTP auth (otherwise rejected) and
//  downloads (otherwise the navigation just fails).
//

import AppKit
import Observation
import SwiftUI
import WebKit

@Observable
@MainActor
final class BrowserSession: NSObject, WebTabContent {
    private(set) var url: URL?
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var isSecure = false
    private(set) var errorMessage: String?
    /// Bumped to ask the toolbar to focus the address field (⌘L, new tab).
    private(set) var addressFocusRequest = 0
    /// Bumped to ask the toolbar to show and focus the find field (⌘F).
    private(set) var findRequest = 0
    var isFindVisible = false

    let kind: WorkspaceTabKind = .browser
    var currentDirectory: String? { nil }

    var displayTitle: String {
        let title = pageTitle.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    @ObservationIgnored private var initialURL: URL?
    @ObservationIgnored private var popupConfiguration: WKWebViewConfiguration?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var container: BrowserHostView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var didReloadAfterCrash = false
    @ObservationIgnored private var downloads: Set<WKDownload> = []
    /// Downloads the user declined in the save panel: their failure is
    /// expected and must not show as an error.
    @ObservationIgnored private var declinedDownloads: Set<WKDownload> = []
    @ObservationIgnored private var lastFindText = ""
    /// The live preferences object. `webView.configuration` hands back a
    /// copy, so changes must go through the one the view was created with.
    @ObservationIgnored private var preferences: WKPreferences?

    init(url: URL?) {
        initialURL = url
        super.init()
    }

    /// A tab opened by a page (`window.open`, `target="_blank"`). WebKit
    /// insists the new web view is built from the configuration it hands
    /// over, or the opener relationship is lost.
    init(popupConfiguration: WKWebViewConfiguration) {
        self.popupConfiguration = popupConfiguration
        super.init()
    }

    // MARK: WebTabContent

    var hostedView: NSView {
        if let container { return container }
        let webView = makeWebView()
        let container = BrowserHostView(
            webView: webView,
            toolbar: NSHostingView(rootView: BrowserToolbar(session: self))
        )
        self.container = container
        self.webView = webView
        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }
        return container
    }

    var hasHostedView: Bool { container != nil }

    /// The web view a popup delegate must return synchronously.
    var webViewForPopup: WKWebView? {
        _ = hostedView
        return webView
    }

    func focus() {
        guard let webView, let window = webView.window else { return }
        if url == nil {
            addressFocusRequest += 1
        } else {
            window.makeFirstResponder(webView)
        }
    }

    func terminate() {
        observations.removeAll()
        for download in downloads { download.cancel(nil) }
        downloads.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        container?.removeFromSuperview()
        container = nil
    }

    // MARK: Navigation

    /// Address bar input. Returns false when the text made no sense.
    @discardableResult
    func load(input: String) -> Bool {
        guard let url = Self.resolve(input: input) else { return false }
        load(url)
        return true
    }

    func load(_ url: URL) {
        errorMessage = nil
        _ = hostedView
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { errorMessage = nil; webView?.reload() }
    func stop() { webView?.stopLoading() }

    func openInDefaultBrowser() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func requestAddressFocus() {
        addressFocusRequest += 1
    }

    /// Returns keyboard focus to the page after the address or find field.
    func focusPage() {
        guard let webView, let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    // MARK: Find and zoom

    func showFind() {
        isFindVisible = true
        findRequest += 1
    }

    func hideFind() {
        isFindVisible = false
        focusPage()
    }

    /// ⌘G / ⇧⌘G: the last search again, or the find bar if there is none.
    func findAgain(backwards: Bool) {
        guard !lastFindText.isEmpty else {
            showFind()
            return
        }
        find(lastFindText, backwards: backwards)
    }

    func find(_ text: String, backwards: Bool = false) {
        lastFindText = text
        guard let webView, !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { _ in }
    }

    func zoomIn() { adjustZoom(by: 0.1) }
    func zoomOut() { adjustZoom(by: -0.1) }
    func resetZoom() { webView?.pageZoom = 1 }

    private func adjustZoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 3)
    }

    // MARK: Address parsing

    /// What the address bar means. Explicit http(s) loads as typed; a bare
    /// host gets a scheme (plain http for local names, which have no
    /// certificates); anything else is a search.
    nonisolated static func resolve(input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        if lowered.hasPrefix("localhost") || looksLikeHost(lowered) {
            let host = lowered.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lowered
            let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
            let hasPort = host.contains(":") && !host.hasPrefix("[")
            // Plain http only where certificates do not exist: loopback and
            // private addresses, .local names, or a bare LAN name typed with
            // a port (a dev server). A bare intranet name without a port is
            // tried over https first; the user can type http:// to insist.
            let scheme = isLocalHost(hostOnly) && (hostOnly.contains(".") || hostOnly == "localhost" || hasPort)
                ? "http" : "https"
            return URL(string: scheme + "://" + text)
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    /// `example.com`, `example.com/path`, `127.0.0.1:3000`, `[::1]:8080`
    /// — but not `how do I quit vim`.
    nonisolated private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostPart.hasPrefix("[") { return true }
        let name = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard !name.isEmpty else { return false }
        if name.contains(".") {
            let labels = name.split(separator: ".")
            return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
        }
        // A single label with a port (`devbox:8080`) is a host on a LAN.
        return hostPart.contains(":") && Int(hostPart.split(separator: ":").last ?? "") != nil
    }

    /// Hosts that are on this machine or this network. They get plain http
    /// by default and keep their sockets alive while the tab is hidden, so
    /// a dev server's hot reload still works.
    nonisolated static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "::1" || name.hasSuffix(".local") || name.hasSuffix(".localhost") {
            return true
        }
        if name.hasPrefix("127.") || name.hasPrefix("10.") || name.hasPrefix("192.168.") || name.hasPrefix("0.0.0.0") {
            return true
        }
        if name.hasPrefix("172.") {
            let second = name.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
            return (16...31).contains(second)
        }
        return !name.contains(".") && !name.isEmpty
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let configuration = popupConfiguration ?? BrowserWebKit.makeConfiguration()
        if popupConfiguration != nil {
            BrowserContentBlocking.shared.apply(to: configuration)
        }
        preferences = configuration.preferences
        let webView = BrowserWebKit.makeWebView(configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageTitle = view.title ?? "" }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isSecure = view.hasOnlySecureContent }
            }
        ]
        return webView
    }

    /// The window a page may put a sheet on: its own, which exists only
    /// while the tab is on screen. A hidden tab gets no window, so its
    /// dialogs are answered with "no" rather than shown over the terminal
    /// the user is typing in — and its sign-in sheet is never shown at all.
    private var window: NSWindow? {
        webView?.window
    }

    private var isOnScreen: Bool {
        webView?.window != nil
    }
}

// MARK: - Navigation policy

extension BrowserSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob":
            decisionHandler(.allow, preferences)
        case "file":
            // Never. A page must not be able to open or launch local files.
            decisionHandler(.cancel, preferences)
        default:
            // mailto:, ssh:, vscode: and friends belong to their own apps —
            // but only when the user clicked a link, and only after they
            // agreed. A hidden frame or a redirect gets nothing.
            decisionHandler(.cancel, preferences)
            guard navigationAction.navigationType == .linkActivated,
                  navigationAction.sourceFrame.isMainFrame else { return }
            BrowserDialogs.confirmExternalOpen(url, in: window) { allowed in
                if allowed { NSWorkspace.shared.open(url) }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    private func adopt(_ download: WKDownload) {
        downloads.insert(download)
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A hidden local page keeps ticking so hot reload survives; a hidden
        // remote page is suspended, which is what keeps the terminal cheap.
        let local = webView.url?.host.map(Self.isLocalHost) ?? false
        preferences?.inactiveSchedulingPolicy = local ? .throttle : .suspend
        didReloadAfterCrash = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancelled is what a redirect or a stop looks like, not a failure.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        else { return }
        errorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM else {
            // Certificates are the system's call; never accept an invalid one.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3, isOnScreen else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        BrowserDialogs.credentials(
            for: challenge.protectionSpace,
            in: window
        ) { credential in
            if let credential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // One automatic reload. A page that keeps crashing stays crashed and
        // says so, instead of looping.
        guard !didReloadAfterCrash else {
            errorMessage = "The page stopped unexpectedly."
            return
        }
        didReloadAfterCrash = true
        webView.reload()
    }
}

// MARK: - Popups and dialogs

extension BrowserSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // What keeps unsolicited popups out is
        // javaScriptCanOpenWindowsAutomatically = false on the configuration,
        // which popups inherit: only a user gesture can reach here. This
        // guard just declines requests aimed at an existing frame.
        guard navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame else {
            return nil
        }
        return BrowserOpener.openPopup(configuration: configuration)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        guard isOnScreen else { completionHandler(); return }
        BrowserDialogs.alert(message, origin: frame.securityOrigin, in: window) { completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard isOnScreen else { completionHandler(false); return }
        BrowserDialogs.confirm(message, origin: frame.securityOrigin, in: window, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard isOnScreen else { completionHandler(nil); return }
        BrowserDialogs.prompt(
            prompt,
            defaultText: defaultText ?? "",
            origin: frame.securityOrigin,
            in: window,
            completion: completionHandler
        )
    }
}

// MARK: - Downloads

extension BrowserSession: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard isOnScreen, let window else {
            declinedDownloads.insert(download)
            completionHandler(nil)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFilename(suggestedFilename)
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let chosen = panel.url else {
                self?.declinedDownloads.insert(download)
                completionHandler(nil)
                return
            }
            // WebKit requires a path that does not exist yet.
            completionHandler(Self.uniqueDestination(for: chosen))
        }
        panel.beginSheetModal(for: window, completionHandler: finish)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.remove(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.remove(download)
        if declinedDownloads.remove(download) != nil { return }
        report(error)
    }

    /// A server's suggested name with path separators and hidden-file
    /// prefixes removed.
    nonisolated static func safeFilename(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.filter { scalar in
            // Controls and bidi formatting characters can make the save
            // panel show a different name than the one written.
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return false }
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return false }
            if scalar.value == 0x200E || scalar.value == 0x200F { return false }
            return true
        }.map(Character.init))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // No hidden files, and no names that are only the separators left
        // over from a path.
        while let first = cleaned.first, first == "." || first == "-" { cleaned.removeFirst() }
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// `file.pdf`, then `file 2.pdf`, `file 3.pdf`… like the Finder.
    nonisolated static func uniqueDestination(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            var candidate = directory.appendingPathComponent("\(base) \(index)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

// MARK: - WebKit setup

@MainActor
enum BrowserWebKit {
    private static let dataStoreKey = "browserDataStoreIdentifier"

    /// One persistent store for every browser tab, separate from the
    /// preview's throwaway store: logins and cookies survive relaunches.
    static let dataStore: WKWebsiteDataStore = {
        let defaults = UserDefaults.standard
        let identifier: UUID
        if let raw = defaults.string(forKey: dataStoreKey), let existing = UUID(uuidString: raw) {
            identifier = existing
        } else {
            identifier = UUID()
            defaults.set(identifier.uuidString, forKey: dataStoreKey)
        }
        return WKWebsiteDataStore(forIdentifier: identifier)
    }()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        // A suffix only. Replacing the whole user agent breaks logins and
        // responsive layouts on sites that sniff it.
        configuration.applicationNameForUserAgent = "Moo/\(version)"
        BrowserContentBlocking.shared.apply(to: configuration)
        return configuration
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = UserDefaults.standard.bool(forKey: "webInspectorEnabled")
        }
        return webView
    }
}

/// Native panels for the page's dialogs, each labelled with the origin that
/// raised it so a page cannot pass its text off as the app's.
@MainActor
enum BrowserDialogs {
    private static func makeAlert(_ message: String, origin: WKSecurityOrigin) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(origin.host.isEmpty ? "This page" : origin.host) says"
        alert.informativeText = message
        return alert
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    static func alert(_ message: String, origin: WKSecurityOrigin, in window: NSWindow?, completion: @escaping () -> Void) {
        let alert = makeAlert(message, origin: origin)
        alert.addButton(withTitle: "OK")
        present(alert, in: window) { _ in completion() }
    }

    static func confirm(_ message: String, origin: WKSecurityOrigin, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, origin: origin)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    static func prompt(
        _ message: String,
        defaultText: String,
        origin: WKSecurityOrigin,
        in window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        let alert = makeAlert(message, origin: origin)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, in: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// A page asked to hand a link to another app (mailto:, ssh:, vscode:…).
    static func confirmExternalOpen(_ url: URL, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Open this link in another app?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    static func credentials(
        for space: URLProtectionSpace,
        in window: NSWindow?,
        completion: @escaping (URLCredential?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.map { "The server says: \($0)" } ?? "The server requires a name and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        user.placeholderString = "Name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        password.placeholderString = "Password"
        stack.addArrangedSubview(user)
        stack.addArrangedSubview(password)
        for field in [user, password] {
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = user

        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }
}

// MARK: - Host view

/// Toolbar above, page below. Plain AppKit so it can live outside the
/// SwiftUI tree with the rest of the tab's state. The toolbar's height
/// follows its content, since the find bar comes and goes.
final class BrowserHostView: NSView {
    private let toolbar: NSHostingView<BrowserToolbar>
    private let webView: WKWebView

    init(webView: WKWebView, toolbar: NSHostingView<BrowserToolbar>) {
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
        let height = max(toolbar.fittingSize.height, 30)
        toolbar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
    }
}
