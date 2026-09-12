//
//  TerminalTitle.swift
//  Moo
//
//  Composes a terminal window title from the profile's title components and
//  reads the process details some of them show. Terminal.app is the model:
//  "moo — vim README.md — -zsh — ttys003 — 100×51".
//

import Darwin
import Foundation

/// Everything a title can show, gathered once per update so that composing
/// the title stays a pure function
struct TerminalTitleInputs: Equatable {
    var customTitle: String?
    /// The title the running program set with OSC 0/2
    var activeTitle = ""
    /// The path the shell reported with OSC 7
    var workingDirectory: String?
    /// argv of the terminal's foreground process
    var foregroundCommand: [String]?
    /// The foreground process is the shell itself, sitting at its prompt
    var foregroundIsShell = false
    /// argv of the shell
    var shellCommand: [String]?
    var profileName = ""
    var ttyName: String?
    var columns = 0
    var rows = 0
}

enum TerminalTitleComposer {
    static let separator = " — "
    /// Longer argument lists are cut; the title bar truncates well before this
    static let argumentLimit = 200

    static func title(for components: Set<TerminalTitleComponent>, inputs: TerminalTitleInputs) -> String {
        var parts: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            parts.append(value)
        }

        append(inputs.customTitle)
        if components.contains(.activeTitle) {
            append(inputs.activeTitle)
        }
        if components.contains(.workingDirectory), let directory = inputs.workingDirectory {
            append(components.contains(.fullPath)
                   ? directory
                   : URL(fileURLWithPath: directory).lastPathComponent)
        }
        let shell = inputs.shellCommand.flatMap { commandDescription($0, includingArguments: false) }
        let showsShell = components.contains(.shellCommandName) && shell != nil
        // At the prompt the foreground process is the shell: name it once.
        if components.contains(.activeProcessName), let command = inputs.foregroundCommand,
           !(inputs.foregroundIsShell && showsShell) {
            append(commandDescription(command, includingArguments: components.contains(.processArguments)))
        }
        if showsShell {
            append(shell)
        }
        if components.contains(.profileName) {
            append(inputs.profileName)
        }
        if components.contains(.ttyName) {
            append(inputs.ttyName)
        }
        if components.contains(.dimensions), inputs.columns > 0, inputs.rows > 0 {
            append("\(inputs.columns)×\(inputs.rows)")
        }
        return parts.joined(separator: separator)
    }

    /// "vim README.md" for ["/usr/bin/vim", "README.md"]. A login shell keeps
    /// its "-zsh" argv[0], as Terminal.app shows it.
    static func commandDescription(_ argv: [String], includingArguments: Bool) -> String? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        let name = (first as NSString).lastPathComponent
        guard includingArguments, argv.count > 1 else { return name }
        var arguments = argv.dropFirst().joined(separator: " ")
        if arguments.count > argumentLimit {
            arguments = String(arguments.prefix(argumentLimit)) + "…"
        }
        return "\(name) \(arguments)"
    }
}

/// Reads what a pty is running. Nothing announces a change of foreground
/// process, so callers poll.
enum TerminalProcessInspector {
    /// The process group in the foreground of the pty: the shell at its
    /// prompt, or the job it is running. Works on the master descriptor.
    static func foregroundProcessGroup(ptyDescriptor: Int32) -> pid_t? {
        guard ptyDescriptor >= 0 else { return nil }
        let group = tcgetpgrp(ptyDescriptor)
        return group > 0 ? group : nil
    }

    /// "ttys003", the device name of the pty's terminal side
    static func ttyName(ptyDescriptor: Int32) -> String? {
        guard ptyDescriptor >= 0, let path = ptsname(ptyDescriptor) else { return nil }
        return (String(cString: path) as NSString).lastPathComponent
    }

    /// argv of a process, or only its name when the arguments are not
    /// readable, as for another user's process such as sudo
    static func commandLine(of pid: pid_t) -> [String]? {
        if let arguments = arguments(of: pid), !arguments.isEmpty {
            return arguments
        }
        guard pid > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return [String(cString: name)]
    }

    /// KERN_PROCARGS2 is argc, the executable path, NUL padding, then argv
    /// followed by the environment.
    static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
