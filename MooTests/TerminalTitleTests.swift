import Darwin
import Foundation
import Testing
@testable import Moo

struct TerminalTitleTests {
    private let sample = TerminalTitleInputs(
        activeTitle: "build",
        workingDirectory: "/Users/me/git/moo",
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
                == "Work — build — moo — vim README.md — -zsh — Default — ttys003 — 100×51")
    }

    @Test func shellAtItsPromptIsNamedOnce() {
        var inputs = sample
        inputs.foregroundCommand = ["-zsh"]
        inputs.foregroundIsShell = true
        #expect(TerminalTitleComposer.title(for: [.activeProcessName, .shellCommandName], inputs: inputs) == "-zsh")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: inputs) == "-zsh")
    }

    @Test func subOptionsExtendTheirParent() {
        #expect(TerminalTitleComposer.title(for: [.workingDirectory], inputs: sample) == "moo")
        #expect(TerminalTitleComposer.title(for: [.workingDirectory, .fullPath], inputs: sample) == "/Users/me/git/moo")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName], inputs: sample) == "vim")
        #expect(TerminalTitleComposer.title(for: [.activeProcessName, .processArguments], inputs: sample)
                == "vim README.md")
    }

    @Test func missingValuesAreSkipped() {
        var inputs = sample
        inputs.ttyName = nil
        inputs.foregroundCommand = nil
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
        profile.titleComponents = [.dimensions, .ttyName, .activeTitle, .shellCommandName]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        #expect(object?["titleComponents"] as? [String] == ["activeTitle", "shellCommandName", "ttyName", "dimensions"])
    }

    @Test func readsTheArgumentsOfARunningProcess() {
        #expect(TerminalProcessInspector.arguments(of: getpid()) == CommandLine.arguments)
        #expect(TerminalProcessInspector.commandLine(of: 0) == nil)
        #expect(TerminalProcessInspector.commandLine(of: -1) == nil)
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
