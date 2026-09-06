//
//  MarkdownSchemeHandler.swift
//  Tecolot
//
//  Serves the preview page, its bundled renderer and the files a document
//  refers to over a private URL scheme:
//
//    tecolot-md://preview/app/<resource>          bundled page, JS, CSS, wasm, fonts
//    tecolot-md://preview/doc/<token>/<relative>  files beside the document
//
//  Not file://. WebKit refuses to instantiate WebAssembly from a file URL
//  (no Content-Type) and treats every file as its own origin, which breaks
//  the renderer's fetch of its grammar engine. One scheme, one host, so the
//  page, its assets and the document's images are all same-origin — and
//  the page cannot reach anything the handler does not choose to serve.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Which directories the handler may read, keyed by an opaque per-tab token
/// so one preview cannot address another's files.
@MainActor
enum MarkdownDocumentRegistry {
    private static var roots: [String: URL] = [:]

    static func register(root: URL) -> String {
        let token = UUID().uuidString
        roots[token] = root.standardizedFileURL.resolvingSymlinksInPath()
        return token
    }

    static func unregister(_ token: String) {
        roots[token] = nil
    }

    static func root(for token: String) -> URL? {
        roots[token]
    }
}

final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tecolot-md"
    static let host = "preview"

    static func appURL(_ name: String) -> URL {
        URL(string: "\(scheme)://\(host)/app/\(name)")!
    }

    static func documentURL(token: String, relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/doc/\(token)/" + relativePath
        return components.url!
    }

    /// Reverses `documentURL`: the file a link inside a preview points at,
    /// if it is under the document's root.
    @MainActor
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let parts = url.pathComponents.dropFirst() // drop "/"
        guard parts.count >= 3, parts.first == "doc",
              let root = MarkdownDocumentRegistry.root(for: parts[parts.startIndex + 1]) else {
            return nil
        }
        let relative = parts.dropFirst(2).joined(separator: "/")
        return resolve(relative, under: root)
    }

    /// Joins and confines: the result is inside the root or nil. Symlinks are
    /// resolved on both sides so a link out of the directory is caught, even
    /// when the final components do not exist yet.
    nonisolated static func resolve(_ relative: String, under root: URL) -> URL? {
        guard !relative.isEmpty, !relative.contains("\0") else { return nil }
        let candidatePath = canonicalPath(root.appendingPathComponent(relative).standardizedFileURL.path)
        let rootPath = canonicalPath(root.standardizedFileURL.path)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) || candidatePath == rootPath else { return nil }
        return URL(fileURLWithPath: candidatePath)
    }

    /// realpath for the part of the path that exists, with the rest appended
    /// untouched. `URL.resolvingSymlinksInPath` gives up on a missing tail,
    /// which would let `link-out/missing` past the root check.
    nonisolated static func canonicalPath(_ path: String) -> String {
        let fileManager = FileManager.default
        var existing = path
        var tail: [String] = []
        while existing != "/", !fileManager.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = (existing as NSString).resolvingSymlinksInPath
        return tail.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }

    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == Self.host else {
            respond(task, status: 404, data: Data(), type: "text/plain")
            return
        }
        let parts = Array(url.pathComponents.dropFirst())
        switch parts.first {
        case "app":
            serveBundled(named: parts.dropFirst().joined(separator: "/"), to: task)
        case "doc":
            serveDocumentFile(parts: Array(parts.dropFirst()), to: task)
        default:
            respond(task, status: 404, data: Data(), type: "text/plain")
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(task))
    }

    /// Bundled resources are looked up by name only: Xcode flattens the
    /// resources folder into the bundle, and the page only ever asks for
    /// files the build script put there.
    private func serveBundled(named path: String, to task: WKURLSchemeTask) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."),
              let url = Bundle.main.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            respond(task, status: 404, data: Data(), type: "text/plain")
            return
        }
        respond(task, status: 200, data: data, type: Self.mimeType(for: url))
    }

    private func serveDocumentFile(parts: [String], to task: WKURLSchemeTask) {
        guard parts.count >= 2 else {
            respond(task, status: 404, data: Data(), type: "text/plain")
            return
        }
        let token = parts[0]
        let relative = parts.dropFirst().joined(separator: "/")
        let rootLookup: URL? = MainActor.assumeIsolated { MarkdownDocumentRegistry.root(for: token) }
        guard let root = rootLookup,
              let file = Self.resolve(relative, under: root) else {
            respond(task, status: 403, data: Data(), type: "text/plain")
            return
        }

        // A markdown file addressed directly is the page itself: the shell
        // that loads the renderer, which then asks the app for the text.
        if LinkRouter.isMarkdown(file.path) {
            serveBundled(named: "markdown-preview.html", to: task)
            return
        }

        let taskID = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async {
                guard let self, !self.stoppedTasks.contains(taskID) else {
                    self?.stoppedTasks.remove(taskID)
                    return
                }
                guard let data else {
                    self.respond(task, status: 404, data: Data(), type: "text/plain")
                    return
                }
                self.respond(task, status: 200, data: data, type: Self.mimeType(for: file))
            }
        }
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, data: Data, type: String) {
        let taskID = ObjectIdentifier(task)
        guard !stoppedTasks.contains(taskID) else {
            stoppedTasks.remove(taskID)
            return
        }
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": type,
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-cache"
                ]
              ) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    nonisolated static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }
}
