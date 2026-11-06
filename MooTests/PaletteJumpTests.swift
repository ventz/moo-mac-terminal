import Foundation
import Testing
@testable import Moo

/// ⌘K's tabs, workspaces and z-style directories.
@MainActor
final class PaletteJumpTests {
    // MARK: Tabs and workspaces

    private func titles(_ model: CommandPaletteModel) -> [String] {
        model.items.map { item in
            switch item {
            case .match(let match): return "match:\(match.text)"
            case .command(let command): return "command:\(command.title)"
            case .place(let place): return "\(place.kind.rawValue):\(place.title)"
            case .directory(let directory): return "dir:\(directory.path)"
            }
        }
    }

    private func place(_ title: String, _ searchText: String, kind: PalettePlace.Kind = .tab,
                       isCurrent: Bool = false, panes: [PalettePlace.Pane] = [],
                       reveal: @escaping @MainActor () -> Void = {}) -> PalettePlace {
        PalettePlace(id: title, kind: kind, title: title, subtitle: "", searchText: "\(title) \(searchText)",
                     isCurrent: isCurrent, panes: panes, reveal: reveal)
    }

    @Test func tabsAreFoundByTitleDirectoryWorkspaceAndProgram() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let scope = WindowScope()
        let api = Project(name: "api")
        let web = Project(name: "web")
        let session = runtime.session(for: api.id)
        let tab = session.ensureTab()
        tab.panes?.focusedController?.updateCurrentDirectory("file://localhost/Users/me/code/billing-service")

        let places = PalettePlaceCollector.places(runtime: runtime, projects: [api, web], scope: scope)
        // Two workspace rows and api's one tab; web was never opened.
        #expect(places.map(\.kind) == [.workspace, .tab, .workspace])
        #expect(runtime.existingSession(for: web.id) == nil)

        let model = CommandPaletteModel(matches: [], commands: [], places: places)
        model.query = "billing"
        #expect(titles(model).contains("Tab:billing-service"))
        // The workspace name finds its tabs; an open workspace has no row of
        // its own, since its tabs are where ↩ should land.
        model.query = "api billing"
        #expect(titles(model) == ["Tab:billing-service"])
        model.query = "me/code"
        #expect(titles(model).contains("Tab:billing-service"))
        model.query = "web"
        #expect(titles(model) == ["Workspace:web"])
    }

    @Test func aWorkspaceNotOpenedYetIsFoundByItsSavedDirectoriesWithoutStartingIt() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let project = Project(name: "later")
        let document = WorkspaceRestoreDocument(
            windows: [],
            workspaces: [SavedWorkspace(projectID: project.id, selectedTabIndex: 0, tabs: [
                SavedTab(root: .terminal(directory: "/srv/payments", profileID: nil, themeOverride: nil))
            ])]
        )
        runtime.prepareRestore(document)

        #expect(runtime.savedDirectories(for: project.id) == ["/srv/payments"])
        let places = PalettePlaceCollector.places(runtime: runtime, projects: [project], scope: WindowScope())
        #expect(places.count == 1)
        #expect(places[0].searchText.contains("/srv/payments"))
        #expect(places[0].subtitle.contains("not opened yet"))
        #expect(runtime.existingSession(for: project.id) == nil)
    }

    @Test func theSplitThatMatchedIsTheOneRevealed() {
        var revealed: [String] = []
        let tab = place("Terminal", "zsh vim", panes: [
            PalettePlace.Pane(searchText: "zsh ~/a") { revealed.append("a") },
            PalettePlace.Pane(searchText: "vim ~/b") { revealed.append("b") }
        ], reveal: { revealed.append("focused") })
        tab.reveal(matching: "vim")
        tab.reveal(matching: "")
        tab.reveal(matching: "nowhere")
        #expect(revealed == ["b", "focused", "focused"])
    }

    @Test func typedQueriesRankTabsThenCommandsThenDirectoriesThenTheScreen() {
        let model = CommandPaletteModel(
            matches: [QuickSelectMatch(kind: .path, text: "/tmp/deploy.log")],
            commands: [PaletteCommand(id: "d", title: "Deploy Thing", path: "Window", shortcut: "") {}],
            places: [place("logs", "~/deploy"), place("deploy", "~/srv")],
            directories: [PaletteDirectory(path: "/srv/deploy", score: 5)],
            directoryExists: { _ in true }
        )
        model.query = "deploy"
        // Title-prefix places first; on-screen text last, so printed output
        // never outranks a tab.
        #expect(titles(model) == ["Tab:deploy", "command:Deploy Thing", "Tab:logs",
                                  "dir:/srv/deploy", "match:/tmp/deploy.log"])
    }

    /// A pane can title itself like a command; the real command still shows
    /// right after it, ahead of tabs that matched elsewhere.
    @Test func aTabTitledLikeACommandCannotBuryIt() {
        let model = CommandPaletteModel(
            matches: [],
            commands: [PaletteCommand(id: "c", title: "Close Tab", path: "File", shortcut: "⌘W") {}],
            places: [place("build", "close tab"), place("Close Tab", "")]
        )
        model.query = "close"
        #expect(titles(model) == ["Tab:Close Tab", "command:Close Tab", "Tab:build"])
    }

    @Test func withNothingTypedTheCurrentTabIsLeftOutAndDirectoriesWait() {
        let model = CommandPaletteModel(
            matches: [],
            commands: [],
            places: [place("here", "", isCurrent: true), place("there", "")],
            directories: [PaletteDirectory(path: "/srv", score: 1)],
            directoryExists: { _ in true }
        )
        #expect(titles(model) == ["Tab:there"])
    }

    @Test func prefixesNarrowTheList() {
        let model = CommandPaletteModel(
            matches: [QuickSelectMatch(kind: .path, text: "/a/moo")],
            commands: [PaletteCommand(id: "m", title: "Moo Thing", path: "", shortcut: "") {}],
            places: [place("moo", ""), place("here", "", isCurrent: true)],
            directories: [PaletteDirectory(path: "/a/moo", score: 2), PaletteDirectory(path: "/b", score: 1)],
            directoryExists: { _ in true }
        )
        model.query = "z moo"
        #expect(titles(model) == ["dir:/a/moo"])
        model.query = "z "
        #expect(titles(model) == ["dir:/a/moo", "dir:/b"])
        model.query = "t moo"
        #expect(titles(model) == ["Tab:moo"])
        model.query = "t "
        #expect(titles(model) == ["Tab:moo"])
        #expect(model.searchWords == "")
        model.query = "Z moo"
        #expect(model.narrowing == .directories)
        model.query = "  z moo"
        #expect(model.narrowing == .directories)
        // No space: a plain search word.
        model.query = "z"
        #expect(model.narrowing == .everything)
    }

    // MARK: The tab list (⌘K with nothing typed, or t )

    @Test func theTabListShowsEveryTabLastUsedFirstAndFilteringKeepsThatOrder() {
        func used(_ place: PalettePlace, _ stamp: Int, open: Bool = false) -> PalettePlace {
            var place = place
            place.lastUsed = stamp
            place.hasOpenTabs = open
            return place
        }
        let model = CommandPaletteModel(
            matches: [],
            commands: [PaletteCommand(id: "c", title: "api command", path: "", shortcut: "") {}],
            places: [
                used(place("api", "", kind: .workspace), 0, open: true),
                used(place("api-server", "~/code/api"), 3),
                used(place("api-logs", "~/code/api"), 7),
                used(place("here", "", isCurrent: true), 9),
                used(place("never-shown", ""), 0),
                used(place("old", "", kind: .workspace), 0)
            ],
            directories: [PaletteDirectory(path: "/srv/api", score: 1)],
            directoryExists: { _ in true }
        )
        model.query = "t "
        // The tab on screen is left out; an open workspace is reached through
        // its tabs; one not reopened yet is listed.
        #expect(titles(model) == ["Tab:api-logs", "Tab:api-server", "Tab:never-shown", "Workspace:old"])
        model.query = "t api"
        // "api-server" starts with the query, but recency still decides.
        #expect(titles(model) == ["Tab:api-logs", "Tab:api-server"])
    }

    @Test func switchingTabsMarksTheTabLastUsed() {
        PlaceRecency.reset()
        let runtime = ProjectRuntime(startsProcesses: false)
        let project = Project(name: "p")
        let session = runtime.session(for: project.id)
        let first = session.ensureTab()
        let second = session.addTab()
        session.select(first)
        #expect(PlaceRecency.stamp(of: first.id) > PlaceRecency.stamp(of: second.id))
        session.select(second)
        #expect(PlaceRecency.stamp(of: second.id) > PlaceRecency.stamp(of: first.id))
        let places = PalettePlaceCollector.places(runtime: runtime, projects: [project], scope: WindowScope())
        #expect(places.first { $0.id == "tab:\(second.id.uuidString)" }?.lastUsed == PlaceRecency.stamp(of: second.id))
        #expect(places.first { $0.kind == .workspace }?.hasOpenTabs == true)
    }

    // MARK: Directories

    /// zsh-z keeps the shell's spelling (/var/…), Moo the kernel's
    /// (/private/var/…): the same directory must be listed once.
    @Test func oneDirectoryUnderTwoSpellingsIsListedOnce() {
        let model = CommandPaletteModel(
            matches: [], commands: [],
            directories: [PaletteDirectory(path: "/private/var/demo/docs", score: 9),
                          PaletteDirectory(path: "/var/demo/docs", score: 5),
                          PaletteDirectory(path: "/var/demo/other-docs", score: 1)],
            directoryExists: { _ in true },
            resolvePath: { $0.hasPrefix("/var/") ? "/private" + $0 : $0 }
        )
        model.query = "z docs"
        #expect(titles(model) == ["dir:/private/var/demo/docs", "dir:/var/demo/other-docs"])
    }

    @Test func directoriesPreferTheirOwnNameThenFrecencyAndSkipMissingOnes() {
        let model = CommandPaletteModel(
            matches: [],
            commands: [],
            directories: [
                PaletteDirectory(path: "/code/moo/docs", score: 50),
                PaletteDirectory(path: "/gone/moo", score: 40),
                PaletteDirectory(path: "/code/moo-mac-terminal", score: 10),
                PaletteDirectory(path: "/code/moo", score: 5)
            ],
            directoryExists: { $0 != "/gone/moo" }
        )
        model.query = "z moo"
        #expect(titles(model) == ["dir:/code/moo-mac-terminal", "dir:/code/moo", "dir:/code/moo/docs"])
    }

    @Test func frecencyMatchesZshZ() {
        let now = 1_000_000.0
        func score(age: Double) -> Double {
            Frecency.score(DirectoryVisit(path: "/a", rank: 8, time: now - age), now: now)
        }
        #expect(score(age: 10) == 32)
        #expect(score(age: 7_200) == 16)
        #expect(score(age: 172_800) == 4)
        #expect(score(age: 1_000_000) == 2)
    }

    @Test func theZshZFileIsParsedAsUntrustedText() {
        let lines = [
            "/Users/me/code|10|1700000000",
            "/Users/me/pipe|in|name|3|1700000000",
            "relative/path|5|1700000000",
            "/Users/me/evil\u{202E}txt|5|1700000000",
            "/Users/me/bad-number|abc|1700000000",
            "/Users/me/nan|nan|1700000000",
            "/Users/me/negative|-4|1700000000",
            "/Users/me/" + String(repeating: "x", count: 5_000) + "|1|1",
            "/Users/me/code/|2|1700000000",
            "garbage"
        ]
        let visits = ZshZData.parse(Data(lines.joined(separator: "\n").utf8))
        let byPath = Dictionary(uniqueKeysWithValues: visits.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["/Users/me/code", "/Users/me/pipe|in|name"])
        // The duplicate with a trailing slash keeps the higher rank.
        #expect(byPath["/Users/me/code"]?.rank == 10)
    }

    @Test func aHugeZshZFileIsCutAtTheCap() {
        let line = "/Users/me/dir|1|1\n"
        let data = Data(String(repeating: line, count: (ZshZData.maximumBytes / line.utf8.count) + 1_000).utf8)
        #expect(data.count > ZshZData.maximumBytes)
        let visits = ZshZData.parse(data)
        #expect(visits.count == 1)
    }

    @Test func theStoreAgesLikeZshZAndSkipsHome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DirectoryHistory.json")
        let history = DirectoryHistory(fileURL: url, homeDirectory: "/Users/me")

        history.record("/Users/me")
        history.record("/")
        history.record("/Users/me/code/")
        history.record("/Users/me/code")
        history.record("/Users/me/evil\nline")
        #expect(history.visits.keys.sorted() == ["/Users/me/code"])
        #expect(history.visits["/Users/me/code"]?.rank == 2)

        for index in 0..<9_000 { history.record("/d/\(index % 3)") }
        let total = history.visits.values.reduce(0) { $0 + $1.rank }
        #expect(total <= DirectoryHistory.maximumTotalRank + 1)

        history.saveNow()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reloaded = DirectoryHistory(fileURL: url, homeDirectory: "/Users/me")
        #expect(reloaded.visits == history.visits)

        reloaded.forgetAll()
        #expect(reloaded.visits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theStoreIsCappedAtItsEntryLimit() {
        let history = DirectoryHistory(homeDirectory: "/Users/me")
        for index in 0..<(DirectoryHistory.maximumEntries + 50) { history.record("/d/\(index)") }
        #expect(history.visits.count == DirectoryHistory.maximumEntries)
    }

    @Test func bothSourcesAreJoinedByPathKeepingTheBetterScore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 2_000_000_000.0
        let z = directory.appendingPathComponent(".z")
        try Data("/shared|100|\(Int(now))\n/only-z|1|\(Int(now))\n".utf8).write(to: z)
        let history = DirectoryHistory(homeDirectory: "/Users/me")
        history.record("/shared", now: now)
        history.record("/only-moo", now: now)

        let joined = history.directories(includingZshZ: true, zURL: z, now: now)
        #expect(joined.map(\.path) == ["/shared", "/only-moo", "/only-z"])
        #expect(joined.first?.score == 400)
        let mooOnly = history.directories(includingZshZ: false, zURL: z, now: now)
        #expect(mooOnly.map(\.path).sorted() == ["/only-moo", "/shared"])
        // "Remember" off hides Moo's own list too.
        let zOnly = history.directories(includingOwn: false, includingZshZ: true, zURL: z, now: now)
        #expect(zOnly.map(\.path) == ["/shared", "/only-z"])

        // A symlinked ~/.z (dotfiles repos) is followed.
        let link = directory.appendingPathComponent("linked-z")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: z)
        #expect(history.zshZVisits(at: link).count == 2)
    }

    // MARK: Recording and jumping

    /// Printed output can send any OSC 7; only a report the kernel agrees
    /// with is counted.
    @Test func aForgedDirectoryReportIsNeverRecorded() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        // As proc_pidinfo reports it: fully resolved, /private included.
        let kernel = try #require(realpath(real.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(kernel.hasPrefix("/private/"))

        #expect(DirectoryPaths.genuine(reported: real.path, kernel: kernel) == real.path)
        // A path that does not exist resolves to nothing.
        #expect(DirectoryPaths.genuine(reported: real.path + "/missing", kernel: kernel) == nil)
        // A real directory the shell is not in, as forged output would name.
        #expect(DirectoryPaths.genuine(reported: "/usr", kernel: kernel) == nil)
        #expect(DirectoryPaths.genuine(reported: real.path, kernel: nil) == nil)
        #expect(DirectoryPaths.genuine(reported: nil, kernel: kernel) == nil)
        #expect(DirectoryPaths.genuine(reported: "/tmp", kernel: "/private/tmp") == "/tmp")
        // Alternate spellings of one directory collapse to the kernel's.
        #expect(DirectoryPaths.genuine(reported: real.path + "/.", kernel: kernel) == kernel)
        #expect(DirectoryPaths.genuine(reported: real.path + "/../" + real.lastPathComponent,
                                       kernel: kernel) == kernel)
    }

    /// Typed, never run (no Return), and only for plain paths: anything a
    /// shell could read differently falls back to opening a tab.
    @Test func cdIsTypedOnlyForPlainPathsAndNeverRun() {
        let clear = DirectoryJump.clearLine
        #expect(DirectoryJump.cdCommand(for: "/Users/me/My Project-2/a_b.c+d,e@f~g=h:i")
                == "\(clear) cd -- '/Users/me/My Project-2/a_b.c+d,e@f~g=h:i'")
        #expect(DirectoryJump.cdCommand(for: "/Users/me/café/日本") != nil)
        #expect(DirectoryJump.cdCommand(for: "/-rf") == "\(clear) cd -- '/-rf'")
        for hostile in ["/it's", "/x\\';touch /tmp/pwn #", "/a$(sh<x)", "/a`id`", "/a!1", "/a;b",
                        "/a*", "/a\nrm -rf ~", "/a\u{202E}b", "relative"] {
            #expect(DirectoryJump.cdCommand(for: hostile) == nil, "\(hostile)")
        }
        #expect(DirectoryJump.cdCommand(for: "/a")?.contains("\r") == false)
    }

    @Test func cdIsNeverTypedIntoAPaneWithoutARunningShell() {
        let runtime = ProjectRuntime(startsProcesses: false)
        let controller = runtime.session(for: UUID()).ensureTab().panes?.focusedController
        #expect(controller?.shellOwnsTerminal == false)
        #expect(!DirectoryJump.changeDirectory(of: controller, to: "/tmp"))
        #expect(!DirectoryJump.changeDirectory(of: nil, to: "/tmp"))
    }

    @Test func aJumpReusesAPaneAlreadyThereFavoringThisWorkspace() {
        final class Pane { let directory: String?; init(_ d: String?) { directory = d } }
        let elsewhere = Pane("/srv/app")
        let here = Pane("/srv/app/")
        let other = Pane("/srv")
        #expect(DirectoryJump.existingPane(for: "/srv/app", among: [elsewhere, here, other],
                                           preferred: [here], directory: \.directory) === here)
        #expect(DirectoryJump.existingPane(for: "/srv/app", among: [elsewhere, other],
                                           preferred: [other], directory: \.directory) === elsewhere)
        #expect(DirectoryJump.existingPane(for: "/nowhere", among: [elsewhere],
                                           preferred: [], directory: \.directory) == nil)
    }
}
