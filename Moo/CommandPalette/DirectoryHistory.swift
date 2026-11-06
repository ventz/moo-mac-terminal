//
//  DirectoryHistory.swift
//  Moo
//
//  The directories ⌘K can jump to, ranked the way zsh-z ranks them: by
//  "frecency", how often and how recently each was visited. Two sources:
//
//  - Moo's own record of where its shells have been. A visit counts only
//    when the shell's real directory, read from the kernel, matches what it
//    reported over OSC 7. Printed output can forge an OSC 7 report; it
//    cannot move the shell, so it cannot plant a directory here.
//  - zsh-z's data file (~/.z), read and never written. It is the user's
//    own file, but it is still parsed as untrusted text: capped in size,
//    and any path with control or bidi characters is dropped.
//

import Foundation
import os

enum CommandPaletteDefaults {
    /// Moo records the directories its shells visit.
    static let remembersDirectories = "commandPaletteRemembersDirectories"
    static let remembersDirectoriesByDefault = true
    /// ⌘K also lists the directories in zsh-z's ~/.z.
    static let readsZshZData = "commandPaletteReadsZshZData"
    static let readsZshZDataByDefault = true

    static func remembersDirectories(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: remembersDirectories) as? Bool ?? remembersDirectoriesByDefault
    }

    static func readsZshZData(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: readsZshZData) as? Bool ?? readsZshZDataByDefault
    }
}

/// One directory and how it has been used. `time` is seconds since 1970,
/// as zsh-z stores it.
struct DirectoryVisit: Codable, Equatable {
    var path: String
    var rank: Double
    var time: Double
}

enum Frecency {
    /// zsh-z's weighting: a visit in the last hour counts four times, in
    /// the last day twice, in the last week half, anything older a quarter.
    static func score(_ visit: DirectoryVisit, now: Double) -> Double {
        let age = now - visit.time
        if age < 3_600 { return visit.rank * 4 }
        if age < 86_400 { return visit.rank * 2 }
        if age < 604_800 { return visit.rank / 2 }
        return visit.rank / 4
    }
}

enum DirectoryPaths {
    static let maximumPathBytes = 4_096

    /// An absolute path with nothing in it that could rewrite a line or
    /// reorder what is shown: no controls, no formatting (bidi) characters,
    /// no line or paragraph separators.
    static func isAcceptable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes else { return false }
        for scalar in path.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: continue
            }
        }
        return true
    }

    /// Trailing slashes dropped, so "/a/b/" and "/a/b" are one entry.
    static func normalized(_ path: String) -> String {
        var value = Substring(path)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return String(value)
    }

    /// The directory a shell reported, if the kernel agrees the shell is
    /// really there. `reported` is the local OSC 7 path; `kernel` the
    /// shell's working directory from proc_pidinfo, which is always fully
    /// resolved, so the report is resolved before comparing. The reported
    /// spelling is kept, as zsh-z keeps $PWD (`/tmp`, not `/private/tmp`).
    ///
    /// A spelling with `.` or `..` in it is replaced by the kernel's path,
    /// so output cannot add `/p/.`, `/p/./.`, … as separate entries.
    static func genuine(reported: String?, kernel: String?) -> String? {
        guard let reported, let kernel, isAcceptable(reported), isAcceptable(kernel),
              let resolved = resolved(reported),
              normalized(resolved) == normalized(kernel) else { return nil }
        let components = reported.split(separator: "/")
        return components.contains(".") || components.contains("..") ? normalized(kernel) : normalized(reported)
    }

    /// realpath, not URL.resolvingSymlinksInPath: that one strips
    /// "/private", so /tmp would never match the kernel's /private/tmp.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// Reads zsh-z's data file: one `path|rank|time` per line.
enum ZshZData {
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumLines = 10_000

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".z")
    }

    static func parse(_ data: Data) -> [DirectoryVisit] {
        // An oversized file is read only as far as the cap: the newest
        // entries are appended at the end, but a damaged file is all a cap
        // can protect against, and the start is as good as any part of it.
        let text = String(decoding: data.prefix(maximumBytes), as: UTF8.self)
        var visits: [String: DirectoryVisit] = [:]
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            if lines > maximumLines { break }
            // Split from the right: a path may itself contain "|".
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let rank = Double(fields[fields.count - 2]), rank.isFinite, rank > 0,
                  let time = Double(fields[fields.count - 1]), time.isFinite, time >= 0 else { continue }
            let path = DirectoryPaths.normalized(fields.dropLast(2).joined(separator: "|"))
            guard DirectoryPaths.isAcceptable(path) else { continue }
            let visit = DirectoryVisit(path: path, rank: min(rank, 1_000_000), time: time)
            if let existing = visits[path], existing.rank >= visit.rank { continue }
            visits[path] = visit
        }
        return Array(visits.values)
    }
}

/// A directory as ⌘K offers it.
struct PaletteDirectory: Identifiable, Equatable {
    let path: String
    let score: Double
    var id: String { path }
    /// What the row shows, with ~ for the home directory.
    var displayPath: String { path.abbreviatedPath }
    var leaf: String { (path as NSString).lastPathComponent }
}

@MainActor
final class DirectoryHistory {
    static let shared = DirectoryHistory()

    /// zsh-z's limits: past a total rank of 9000 every rank is scaled down
    /// and the ones that fall under 1 are forgotten.
    static let maximumTotalRank = 9_000.0
    static let maximumEntries = 1_000
    static let maximumFileBytes = 1_000_000
    static let saveDelay: TimeInterval = 5

    private(set) var visits: [String: DirectoryVisit] = [:]
    private var fileURL: URL?
    private let homeDirectory: String
    private var saveTimer: Timer?
    private var isDirty = false
    private var zCache: (url: URL, modified: Date, size: Int, visits: [DirectoryVisit])?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.vpetkov.Moo",
        category: "DirectoryHistory"
    )

    init(fileURL: URL? = nil,
         homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = DirectoryPaths.normalized(homeDirectory)
        if let fileURL { load(from: fileURL) }
    }

    /// Points the store at Moo's Application Support folder and reads it.
    func configure(directory: URL) {
        load(from: directory.appendingPathComponent("DirectoryHistory.json"))
    }

    private func load(from url: URL) {
        fileURL = url
        visits = [:]
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url), data.count <= Self.maximumFileBytes,
              let saved = try? JSONDecoder().decode([DirectoryVisit].self, from: data) else { return }
        for visit in saved.prefix(Self.maximumEntries)
        where DirectoryPaths.isAcceptable(visit.path) && visit.rank.isFinite && visit.rank > 0 && visit.time.isFinite {
            var visit = visit
            visit.path = DirectoryPaths.normalized(visit.path)
            visits[visit.path] = visit
        }
    }

    /// Counts a visit. Home and / are left out, as zsh-z leaves out home:
    /// every shell starts there, so they would always lead.
    func record(_ path: String, now: Double = Date().timeIntervalSince1970) {
        let path = DirectoryPaths.normalized(path)
        guard DirectoryPaths.isAcceptable(path), path != "/", path != homeDirectory else { return }
        var visit = visits[path] ?? DirectoryVisit(path: path, rank: 0, time: now)
        visit.rank += 1
        visit.time = now
        visits[path] = visit
        age(now: now)
        markDirty()
    }

    private func age(now: Double) {
        let total = visits.values.reduce(0) { $0 + $1.rank }
        if total > Self.maximumTotalRank {
            visits = visits.compactMapValues { visit in
                var aged = visit
                aged.rank *= 0.99
                return aged.rank >= 1 ? aged : nil
            }
        }
        if visits.count > Self.maximumEntries {
            let kept = visits.values
                .sorted { Frecency.score($0, now: now) > Frecency.score($1, now: now) }
                .prefix(Self.maximumEntries)
            visits = Dictionary(uniqueKeysWithValues: kept.map { ($0.path, $0) })
        }
    }

    func forgetAll() {
        visits = [:]
        saveTimer?.invalidate()
        saveTimer = nil
        isDirty = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Every directory either source knows, best first. The two are joined
    /// by path, keeping whichever scores higher.
    func directories(includingOwn: Bool = true,
                     includingZshZ: Bool,
                     zURL: URL = ZshZData.defaultURL,
                     now: Double = Date().timeIntervalSince1970) -> [PaletteDirectory] {
        var best: [String: Double] = [:]
        for visit in visits.values where includingOwn {
            best[visit.path] = Frecency.score(visit, now: now)
        }
        if includingZshZ {
            for visit in zshZVisits(at: zURL) {
                let score = Frecency.score(visit, now: now)
                if score > best[visit.path] ?? -1 { best[visit.path] = score }
            }
        }
        return best.map { PaletteDirectory(path: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    /// The parsed file, read again only when it changes. Opened before it
    /// is checked, without blocking: a symlinked ~/.z (dotfiles repos) is
    /// followed, and a FIFO swapped in cannot stall the main thread.
    func zshZVisits(at url: URL) -> [DirectoryVisit] {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return [] }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                            + Double(info.st_mtimespec.tv_nsec) / 1e9)
        let size = Int(info.st_size)
        if let zCache, zCache.url == url, zCache.modified == modified, zCache.size == size {
            return zCache.visits
        }
        let data = (try? handle.read(upToCount: ZshZData.maximumBytes)) ?? Data()
        let parsed = ZshZData.parse(data)
        zCache = (url, modified, size, parsed)
        return parsed
    }

    // MARK: Saving

    private func markDirty() {
        isDirty = true
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// Writes pending visits. Readable by the user alone, renamed into
    /// place, so it is never briefly 0644: the list says where someone works.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty, let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ordered = visits.values.sorted { $0.path < $1.path }
        guard let data = try? encoder.encode(ordered) else { return }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            Self.logger.error("Could not save directory history: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Only now: a failed write stays pending for the next save.
            isDirty = false
        } catch {
            unlink(temporary.path)
            Self.logger.error("Could not save directory history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
