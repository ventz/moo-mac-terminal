//
//  MarkdownFileWatcher.swift
//  Tecolot
//
//  Tells a preview when its file changes. Watches the file's directory, not
//  the file: vim, VS Code and most editors save by writing a temporary file
//  and renaming it over the original, so a source bound to the old inode
//  fires once and then watches a dead file forever. Directory events are
//  debounced, and the file is re-read and hashed so a save that changed
//  nothing does not redraw the page.
//

import CryptoKit
import Darwin
import Foundation

@MainActor
final class MarkdownFileWatcher {
    enum Event {
        case changed(String)
        case missing
    }

    private let fileURL: URL
    private let handler: (Event) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?
    private var lastDigest: SHA256Digest?
    private let debounce: TimeInterval

    init(fileURL: URL, debounce: TimeInterval = 0.3, handler: @escaping (Event) -> Void) {
        self.fileURL = fileURL.standardizedFileURL
        self.debounce = debounce
        self.handler = handler
    }

    /// Reads the file now and starts watching. The first read always fires
    /// so the caller has content to show.
    func start() {
        reload(force: true)
        watchDirectory()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    /// The manual reload button: re-read even if nothing seemed to change.
    func reload(force: Bool = false) {
        guard let data = try? Data(contentsOf: fileURL) else {
            lastDigest = nil
            handler(.missing)
            return
        }
        let digest = SHA256.hash(data: data)
        guard force || digest != lastDigest else { return }
        lastDigest = digest
        handler(.changed(String(decoding: data, as: UTF8.self)))
    }

    private func watchDirectory() {
        source?.cancel()
        let directory = fileURL.deletingLastPathComponent().path
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            // The directory itself moved or vanished: the descriptor now
            // points nowhere useful. Re-open after the debounce.
            let needsReopen = flags.contains(.rename) || flags.contains(.delete)
            self.schedule(reopen: needsReopen)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    private func schedule(reopen: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if reopen {
                self.watchDirectory()
            }
            self.reload()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
