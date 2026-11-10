//
//  HerdrCoreLaunch.swift
//  Moo
//
//  Settings → herdr → "Run new tabs and splits in herdr-core". Off by
//  default. When on, a new pane does not run the shell itself: it runs a
//  short `sh` script that starts the shell in a new herdr-core terminal
//  (`hc run --bg`) and attaches to it (`exec hc attach`), so the shell, and
//  any agent started in it, keeps running when the tab closes or Moo quits,
//  and agents there report to the agent panel.
//
//  The pane runs `hc` itself, as if the user had typed it: Moo still never
//  writes to herdr's socket. When `hc` is missing or cannot start a
//  terminal, the script runs the shell in the pane as usual.
//
//  A tab Moo opens to run a command of its own (the panel's own
//  `hc attach`, an install command) is left alone: wrapping it would put
//  one attach inside another.
//

import Foundation

nonisolated enum HerdrCoreLaunch {
    /// The script the pane runs: $1 is hc's path, the rest is the shell or
    /// command the pane would have run. Its first line of output is
    /// herdr-core's JSON reply; the address is taken from it with sed, so
    /// nothing beyond /bin/sh is needed.
    static let script = #"""
        hc="$1"; shift
        out=$("$hc" run --bg --json --rm --no-parent --no-notify --label moo=1 --cwd "$PWD" -- "$@" 2>/dev/null)
        t=$(printf '%s\n' "$out" | sed -n 's/.*"address": *"\([A-Za-z0-9_./-]*\)".*/\1/p' | head -n 1)
        if [ -n "$t" ]; then exec "$hc" attach "$t"; fi
        echo "Moo: herdr-core did not start a terminal; this shell runs in Moo instead." >&2
        exec "$@"
        """#

    /// The launch that runs `parameters` in herdr-core instead. A login
    /// shell (argv[0] starting with "-") is asked for with `-l`, since a
    /// program started by herdr-core cannot be given its own argv[0].
    @MainActor
    static func wrap(_ parameters: LaunchParameters, hcPath: String) -> LaunchParameters {
        var program = [parameters.executable] + parameters.args
        if parameters.execName?.hasPrefix("-") == true {
            program.append("-l")
        }
        return LaunchParameters(
            executable: "/bin/sh",
            args: ["-c", script, "moo-herdr-core", hcPath] + program,
            execName: nil,
            environment: parameters.environment,
            currentDirectory: parameters.currentDirectory
        )
    }

    /// Where `hc` is: the herdr-core installer's ~/.local/bin, or Homebrew.
    /// Looked up rather than taken from PATH, which a Moo opened from the
    /// Dock does not have.
    static func hcPath(
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let candidates = [
            (home as NSString).appendingPathComponent(".local/bin/hc"),
            "/opt/homebrew/bin/hc",
            "/usr/local/bin/hc",
        ]
        return candidates.first(where: isExecutable)
    }
}
