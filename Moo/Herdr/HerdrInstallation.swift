//
//  HerdrInstallation.swift
//  Moo
//
//  What Settings → Notifications → herdr says about herdr on this Mac:
//  where it is, which version, and what to do when it is missing. Moo never
//  installs anything itself; "Install in New Tab" only types the command.
//

import AppKit
import Foundation

enum HerdrInstallation: Equatable {
    case checking
    case found(path: String, version: String)
    case tooOld(path: String, version: String)
    /// `brew` is the Homebrew path when Homebrew is installed.
    case missing(brew: String?)

    static let installCommand = "brew install herdr"
    static let upgradeCommand = "brew upgrade herdr"
    static let installPage = URL(string: "https://herdr.dev/docs/install/")!

    /// Where herdr's installers put it: Homebrew on Apple silicon and Intel,
    /// herdr's own install.sh, mise, cargo.
    nonisolated static func candidatePaths(home: String) -> [String] {
        [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "\(home)/.local/bin/herdr",
            "\(home)/.local/share/mise/shims/herdr",
            "\(home)/.cargo/bin/herdr",
        ]
    }

    /// Only a Homebrew install is upgraded with `brew upgrade`.
    nonisolated static func isHomebrewPath(_ path: String) -> Bool {
        path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
    }

    nonisolated static func homebrewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Looks for herdr and asks it its version, on a thread of its own, with
    /// one deadline for the whole check. Only the known install locations
    /// and Moo's own PATH are searched: running a login shell to find it
    /// would run the user's shell startup files.
    nonisolated static func check(timeout: TimeInterval = 3) async -> HerdrInstallation {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: checkNow(timeout: timeout))
            }
        }
    }

    nonisolated static func checkNow(timeout: TimeInterval) -> HerdrInstallation {
        let home = NSHomeDirectory()
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/herdr" }
        let path = (candidatePaths(home: home) + pathDirectories)
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        guard let path else { return .missing(brew: homebrewPath()) }
        let output = run(path, arguments: ["--version"], timeout: timeout) ?? ""
        guard let version = HerdrProtocol.version(fromVersionOutput: output) else {
            return .tooOld(path: path, version: "unknown")
        }
        let text = "\(version.major).\(version.minor).\(version.patch)"
        return HerdrProtocol.isSupported(version)
            ? .found(path: path, version: text)
            : .tooOld(path: path, version: text)
    }

    /// Runs a program with no input and returns what it printed, or nil
    /// when it fails or misses the deadline. Output is read as it arrives
    /// and capped, so a child that keeps the pipe open cannot hang the
    /// check; on the deadline the program is killed.
    nonisolated static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.withLock {
                if output.count < 4_096 { output.append(chunk.prefix(4_096 - output.count)) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let deadline = DispatchTime.now() + timeout
        if exited.wait(timeout: deadline) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // Let the last of the output land, without waiting on whoever else
        // may still hold the pipe.
        Thread.sleep(forTimeInterval: 0.05)
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else { return nil }
        return lock.withLock { String(decoding: output, as: UTF8.self) }
    }

    /// A new tab in the frontmost workspace with `command` typed at the
    /// prompt and not run: the user reads it and presses Return.
    @MainActor
    static func typeInNewTab(_ command: String) {
        let runtime = ProjectRuntime.shared
        guard let session = runtime.selectedSession else {
            NSSound.beep()
            return
        }
        let tab = session.addTab()
        tab.panes?.focusedController?.typeWhenStarted(command)
        runtime.invalidate()
        if let window = runtime.keyScope.window ?? NSApp.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
