import Darwin
import Foundation
import Testing
@testable import Moo

struct TerminalTitleTests {
    private let sample = TerminalTitleInputs(
        activeTitle: "build",
        workingDirectory: "/Users/me/git/moo",
        homeDirectory: "/Users/me",
        foregroundCommand: ["/usr/bin/vim", "README.md"],
        shellCommand: ["-zsh"],
        profileName: "Default",
        ttyName: "ttys003",
        columns: 100,
        rows: 51
    )

    @Test func componentsFollowTerminalAppOrder() {
        let components: Set<TerminalTitleComponent> = [
            .dimensions, .ttyName, .profileName, .shellCommandName,
            .processArguments, .activeProcessName, .workingDirectory, .activeTitle,
        ]
        var inputs = sample
        inputs.customTitle = "Work"
        #expect(TerminalTitleComposer.title(for: components, inputs: inputs)
                == "Work — moo — build — vim README.md — zsh — Default — ttys003 — 100×51")
    }

    /// Terminal.app at a prompt: "/tmp — -zsh — zsh"
    @Test func shellAtItsPromptShowsProcessAndShellName() {
        var inputs = sample
        inputs.foregroundCommand = ["-zsh"]
        #expect(TerminalTitleComposer.title(for: [.activeProcessName, .shellCommandName], inputs: inputs) == "-zsh — zsh")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: inputs) == "-zsh")
        #expect(TerminalTitleComposer.title(for: [.shellCommandName], inputs: inputs) == "zsh")
    }

    @Test func subOptionsExtendTheirParent() {
        #expect(TerminalTitleComposer.title(for: [.workingDirectory], inputs: sample) == "moo")
        #expect(TerminalTitleComposer.title(for: [.workingDirectory, .fullPath], inputs: sample) == "~/git/moo")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: sample) == "vim")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName, .processArguments], inputs: sample)
                == "vim README.md")
    }

    @Test func fullPathAbbreviatesOnlyTheHomeFolder() {
        #expect(TerminalTitleComposer.abbreviatingHome("/Users/me", home: "/Users/me") == "~")
        #expect(TerminalTitleComposer.abbreviatingHome("/Users/me/git", home: "/Users/me/") == "~/git")
        #expect(TerminalTitleComposer.abbreviatingHome("/Users/meow/git", home: "/Users/me") == "/Users/meow/git")
        #expect(TerminalTitleComposer.abbreviatingHome("/tmp", home: "/Users/me") == "/tmp")
        #expect(TerminalTitleComposer.abbreviatingHome("/tmp", home: nil) == "/tmp")
    }

    /// Terminal.app: "python ◂ claude --dangerously-skip-permissions"
    @Test func runningProcessIsShownBeforeTheLeaderThatStartedIt() {
        var inputs = sample
        inputs.foregroundCommand = ["claude", "--dangerously-skip-permissions"]
        inputs.foregroundDescendant = ["/usr/local/bin/python", "server.py"]
        #expect(TerminalTitleComposer.title(for: [.activeProcessName, .processArguments], inputs: inputs)
                == "python ◂ claude --dangerously-skip-permissions")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: inputs) == "python ◂ claude")
        inputs.foregroundDescendant = ["/opt/claude"]
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: inputs) == "claude")
    }

    @Test func missingValuesAreSkipped() {
        var inputs = sample
        inputs.ttyName = nil
        inputs.foregroundCommand = nil
        inputs.foregroundDescendant = ["python"]
        inputs.columns = 0
        #expect(TerminalTitleComposer.title(for: [.ttyName, .activeProcessName, .dimensions, .profileName], inputs: inputs)
                == "Default")
    }

    @Test func longArgumentListsAreCut() throws {
        let argument = String(repeating: "a", count: 500)
        let description = try #require(TerminalTitleComposer.commandDescription(["cat", argument], includingArguments: true))
        #expect(description == "cat " + String(repeating: "a", count: TerminalTitleComposer.argumentLimit) + "…")
    }

    @Test func loadingDropsUnknownComponentsAndEnablesParents() throws {
        let json = #"{"name":"Old","titleComponents":["fullPath","fromTheFuture","processArguments"]}"#
        let profile = try JSONDecoder().decode(TerminalProfile.self, from: Data(json.utf8))
        #expect(profile.titleComponents == [.fullPath, .workingDirectory, .processArguments, .activeProcessName])
    }

    @Test func componentsSaveInTitleOrder() throws {
        var profile = TerminalProfile(name: "Ordered")
        profile.titleComponents = [.dimensions, .ttyName, .activeTitle, .shellCommandName, .workingDirectory]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        #expect(object?["titleComponents"] as? [String]
                == ["workingDirectory", "activeTitle", "shellCommandName", "ttyName", "dimensions"])
    }

    @Test func readsTheArgumentsOfARunningProcess() {
        #expect(TerminalProcessInspector.arguments(of: getpid()) == CommandLine.arguments)
        #expect(TerminalProcessInspector.commandLine(of: 0) == nil)
        #expect(TerminalProcessInspector.commandLine(of: -1) == nil)
    }

    /// sh → sh → sleep, all in one new process group: the grandchild wins
    @Test func findsTheDeepestProcessInTheForegroundGroup() throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let words: [String] = ["/bin/sh", "-c", "/bin/sh -c '/bin/sleep 30; :'; :"]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var leader: pid_t = 0
        try #require(posix_spawn(&leader, "/bin/sh", nil, &attributes, argv, environ) == 0)
        defer {
            kill(-leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }

        var found: [String]?
        for _ in 0..<60 where found?.first != "/bin/sleep" {
            usleep(50_000)
            found = TerminalProcessInspector.deepestDescendant(inGroup: leader)
                .flatMap(TerminalProcessInspector.commandLine(of:))
        }
        #expect(found == ["/bin/sleep", "30"])
        #expect(TerminalProcessInspector.deepestDescendant(inGroup: -1) == nil)
    }

    @Test func namesThePtyDevice() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        #expect(grantpt(master) == 0)
        #expect(unlockpt(master) == 0)
        let name = try #require(TerminalProcessInspector.ttyName(ptyDescriptor: master))
        #expect(name.hasPrefix("ttys"))
        // No session owns this pty, so nothing is in its foreground.
        #expect(TerminalProcessInspector.foregroundProcessGroup(ptyDescriptor: master) == nil)
        #expect(TerminalProcessInspector.ttyName(ptyDescriptor: -1) == nil)
    }
}
