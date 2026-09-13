//
//  TerminalTitle.swift
//  Moo
//
//  Composes a terminal window title from the profile's title components and
//  reads the process details some of them show. Terminal.app is the model:
//  "~/git/moo — ✳ Task — python ◂ claude --flag — zsh — ttys003 — 100×51".
//

import Darwin
import Foundation

/// Everything a title can show, gathered once per update so that composing
/// the title stays a pure function
struct TerminalTitleInputs: Equatable {
    var customTitle: String?
    /// The title a running program set with OSC 0/2
    var activeTitle = ""
    /// The path the shell reported with OSC 7
    var workingDirectory: String?
    /// Shown as "~" at the start of a full path
    var homeDirectory: String?
    /// argv of the leader of the terminal's foreground process group
    var foregroundCommand: [String]?
    /// argv of the deepest process below that leader in the same group, such
    /// as the python a claude session started
    var foregroundDescendant: [String]?
    /// argv of the shell
    var shellCommand: [String]?
    var profileName = ""
    var ttyName: String?
    var columns = 0
    var rows = 0
}

enum TerminalTitleComposer {
    static let separator = " — "
    /// Joins the running process to the one that started it: "python ◂ claude"
    static let processSeparator = " ◂ "
    /// Longer argument lists are cut; the title bar truncates well before this
    static let argumentLimit = 200

    static func title(for components: Set<TerminalTitleComponent>, inputs: TerminalTitleInputs) -> String {
        var parts: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            parts.append(value)
        }

        append(inputs.customTitle)
        if components.contains(.workingDirectory), let directory = inputs.workingDirectory {
            append(components.contains(.fullPath)
                   ? abbreviatingHome(directory, home: inputs.homeDirectory)
                   : URL(fileURLWithPath: directory).lastPathComponent)
        }
        if components.contains(.activeTitle) {
            append(inputs.activeTitle)
        }
        if components.contains(.activeProcessName) {
            append(processDescription(inputs, includingArguments: components.contains(.processArguments)))
        }
        if components.contains(.shellCommandName) {
            append(shellName(inputs.shellCommand))
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

    /// "python ◂ claude --flag": the running process, then the group leader
    /// that started it, whose arguments are the ones shown. At a prompt the
    /// leader is the shell, "-zsh".
    static func processDescription(_ inputs: TerminalTitleInputs, includingArguments: Bool) -> String? {
        guard let command = inputs.foregroundCommand,
              let leader = commandDescription(command, includingArguments: includingArguments) else {
            return nil
        }
        guard let descendant = inputs.foregroundDescendant.flatMap({ commandDescription($0, includingArguments: false) }),
              descendant != commandDescription(command, includingArguments: false) else {
            return leader
        }
        return descendant + processSeparator + leader
    }

    /// "zsh" for a login shell's "-zsh"
    static func shellName(_ argv: [String]?) -> String? {
        guard let argv, let name = commandDescription(argv, includingArguments: false) else { return nil }
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return bare.isEmpty ? nil : bare
    }

    static func abbreviatingHome(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == root { return "~" }
        if path.hasPrefix(root + "/") { return "~" + path.dropFirst(root.count) }
        return path
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

    /// The process furthest below the group's leader that is still in its
    /// group, newest first among equals: the python a claude session runs,
    /// not claude. Nil when the leader runs nothing in its group.
    static func deepestDescendant(inGroup group: pid_t) -> pid_t? {
        guard group > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard needed > 0 else { return nil }
        // Room for processes started between the two calls
        var pids = [pid_t](repeating: 0, count: Int(needed) / stride + 16)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return nil }

        var parents: [pid_t: (parent: pid_t, started: UInt64)] = [:]
        for pid in pids.prefix(Int(filled) / stride) where pid > 0 && pid != group {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let started = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            parents[pid] = (pid_t(info.pbi_ppid), started)
        }

        /// Steps up to the leader, or nil when the chain leaves the group
        func depth(of pid: pid_t) -> Int? {
            var current = pid
            var steps = 0
            while let entry = parents[current] {
                steps += 1
                if entry.parent == group { return steps }
                current = entry.parent
                if steps > parents.count { return nil }
            }
            return nil
        }

        var best: (pid: pid_t, depth: Int, started: UInt64)?
        for (pid, entry) in parents {
            guard let steps = depth(of: pid) else { continue }
            if let current = best,
               (current.depth, current.started) >= (steps, entry.started) {
                continue
            }
            best = (pid, steps, entry.started)
        }
        return best?.pid
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
