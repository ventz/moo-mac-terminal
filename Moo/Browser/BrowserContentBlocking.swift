//
//  BrowserContentBlocking.swift
//  Moo
//
//  Ad and tracker blocking for browser tabs, using WebKit's own mechanism:
//  WKContentRuleList, the declarative rule format Safari content blockers
//  use. A WKWebView cannot load browser extensions, so uBlock Origin Lite
//  itself is out of reach — but its Safari port ships its filter lists in
//  exactly this format, and those rulesets are what the app bundles.
//
//  The rulesets come from AdGuard's Safari-optimized lists (EasyList plus
//  AdGuard's own, and AdGuard Tracking Protection), converted at build time
//  by tools/adblock/build.sh and shipped as raw DEFLATE. They are inflated
//  and compiled once per list version and cached by WebKit under an
//  identifier; later launches attach the cached lists in milliseconds.
//

import Compression
import Foundation
import WebKit

enum ContentBlockingDefaults {
    static let enabledKey = "browserContentBlockingEnabled"

    static let registrationValues: [String: Any] = [
        enabledKey: true
    ]

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

@MainActor
final class BrowserContentBlocking {
    static let shared = BrowserContentBlocking()

    struct Ruleset: Decodable, Equatable {
        var name: String
        var title: String
        var source: String
        var version: String
        var updated: String
        var rules: Int
        var file: String
    }

    struct Manifest: Decodable {
        var safariVersion: String
        var converter: String
        var built: String
        var lists: [Ruleset]
    }

    /// Compiled lists, once ready. Configurations created before compilation
    /// finishes get them attached retroactively through `apply(to:)`.
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var isReady = false
    private(set) var failures: [String: String] = [:]
    private var compilation: Task<Void, Never>?
    /// Weak: a closed tab's controller must not be kept alive by this list.
    private let attachedControllers = NSHashTable<WKUserContentController>.weakObjects()

    private init() {}

    /// The bundled manifest written by tools/adblock/build.sh.
    static func manifest(in bundle: Bundle = .main) -> Manifest? {
        guard let url = bundle.url(forResource: "adblock-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The cache key for a list: its name and the list version it was built
    /// from, so a refreshed bundle never reuses a stale compiled list.
    nonisolated static func identifier(for ruleset: Ruleset) -> String {
        "adblock-\(ruleset.name)@\(ruleset.version)"
    }

    /// Inflates a bundled `.deflate` ruleset back into its JSON text.
    nonisolated static func inflate(_ data: Data, expectedSize: Int) throws -> String {
        let inflated = try (data as NSData).decompressed(using: .zlib) as Data
        guard let text = String(data: inflated, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    /// Compiles (or loads from WebKit's cache) every bundled ruleset. Safe
    /// to call repeatedly; only the first call does work.
    func prepare() {
        guard compilation == nil else { return }
        compilation = Task { [weak self] in
            guard let self else { return }
            let store = WKContentRuleListStore.default()!
            var lists: [WKContentRuleList] = []
            guard let manifest = Self.manifest() else {
                self.isReady = true
                return
            }
            for ruleset in manifest.lists {
                let identifier = Self.identifier(for: ruleset)
                do {
                    if let cached = try await store.contentRuleList(forIdentifier: identifier) {
                        lists.append(cached)
                        continue
                    }
                    guard let url = Bundle.main.url(forResource: ruleset.file, withExtension: nil) else {
                        self.failures[identifier] = "Missing \(ruleset.file)"
                        continue
                    }
                    // Inflating ~12 MB of JSON is off the main thread; the
                    // compile itself is WebKit's, on its own queue.
                    let json = try await Task.detached(priority: .utility) {
                        try Self.inflate(try Data(contentsOf: url), expectedSize: ruleset.rules)
                    }.value
                    if let compiled = try await store.compileContentRuleList(
                        forIdentifier: identifier,
                        encodedContentRuleList: json
                    ) {
                        lists.append(compiled)
                    }
                } catch {
                    self.failures[identifier] = error.localizedDescription
                }
            }
            // Drop compiled lists from older bundles.
            if let identifiers = try? await store.availableIdentifiers() {
                let current = Set(manifest.lists.map(Self.identifier(for:)))
                for stale in identifiers where stale.hasPrefix("adblock-") && !current.contains(stale) {
                    try? await store.removeContentRuleList(forIdentifier: stale)
                }
            }
            self.ruleLists = lists
            self.isReady = true
            for controller in self.attachedControllers.allObjects {
                self.attach(to: controller)
            }
        }
    }

    /// Registers a configuration so it gets the lists now if they are ready,
    /// or as soon as they are.
    func apply(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        attachedControllers.add(controller)
        if isReady {
            attach(to: controller)
        }
        prepare()
    }

    /// Turns blocking on or off for every browser tab, live.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ContentBlockingDefaults.enabledKey)
        for controller in attachedControllers.allObjects {
            attach(to: controller)
        }
    }

    private func attach(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        guard ContentBlockingDefaults.isEnabled else { return }
        for list in ruleLists {
            controller.add(list)
        }
    }

    var rulesetCount: Int { ruleLists.count }
}
