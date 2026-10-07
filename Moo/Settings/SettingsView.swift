//
//  SettingsView.swift
//  Moo
//
//  Settings window. The sidebar is grouped by scope: the first group is
//  app-wide, the second edits the profile picked in the Settings toolbar,
//  and the last holds updates and data. A search field filters every
//  setting by name (SettingsSearch.swift).
//
import Combine
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator
    @EnvironmentObject private var profiles: ProfileStore

    @State private var destination: SettingsDestination? = .general
    @State private var activeProfileID: TerminalProfile.ID?
    @State private var profileErrorMessage: String?
    @State private var searchText = ""
    /// Search results are selected one by one, by entry; selecting one opens
    /// its page. Tagging rows by page instead highlighted every match on it.
    @State private var searchSelection: SettingsSearch.Entry.ID?

    var body: some View {
        NavigationSplitView {
            Group {
                if SettingsSearch.isSearching(searchText) {
                    List(selection: $searchSelection) {
                        searchResults
                    }
                    .onChange(of: searchSelection) { _, id in
                        guard let entry = SettingsSearch.entries.first(where: { $0.id == id }) else { return }
                        choose(entry)
                    }
                } else {
                    List(selection: $destination) {
                        ForEach(SettingsDestination.Group.allCases) { group in
                            Section {
                                ForEach(group.destinations) { destination in
                                    Label(sidebarTitle(for: destination), systemImage: destination.systemImage)
                                        .tag(destination)
                                }
                            } header: {
                                if let title = group.title {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
            .navigationTitle("Settings")
            .frame(minWidth: 190)
        } detail: {
            // Scrolls the chosen search result into view once its page is
            // up; the setting's own anchor then outlines it.
            // A setting already on screen is scrolled to at once; one whose
            // page is still opening asks again when its anchor appears
            // (SettingsHighlight.scrollRequest), rather than this guessing
            // how long the page takes.
            ScrollViewReader { proxy in
                detail
                    .onChange(of: SettingsHighlight.shared.request) { _, request in
                        guard let request else { return }
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(request.anchorID, anchor: .center) }
                        }
                    }
                    .onChange(of: SettingsHighlight.shared.scrollRequest) { _, _ in
                        guard let request = SettingsHighlight.shared.request else { return }
                        withAnimation { proxy.scrollTo(request.anchorID, anchor: .center) }
                    }
            }
        }
        .toolbar {
            if currentDestination.isProfileDriven {
                ToolbarItem(placement: .automatic) {
                    profileMenu
                }
            }
            // The standard round help button: opens this page's section of
            // docs/SETTINGS.md, which documents every setting with examples.
            ToolbarItem(placement: .automatic) {
                HelpLink {
                    NSWorkspace.shared.open(currentDestination.documentationURL)
                }
                .help("Open the documentation for \(currentDestination.title)")
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(SettingsEscapeKeyHandler())
        .onAppear(perform: repairActiveProfileSelection)
        .onChange(of: profiles.profiles.map(\.id)) {
            repairActiveProfileSelection()
        }
        .onChange(of: activeProfileID) {
            repairActiveProfileSelection()
        }
        .alert("Could Not Change Profile", isPresented: profileErrorPresentation) {
            Button("OK") {
                profileErrorMessage = nil
            }
        } message: {
            Text(profileErrorMessage ?? "An unknown error occurred.")
        }
    }

    /// Matching settings, grouped under their page. Selecting one opens its
    /// page; the search stays so the next match is one click away.
    @ViewBuilder
    private var searchResults: some View {
        let groups = SettingsSearch.results(for: searchText)
        if groups.isEmpty {
            Text("No settings match \u{201C}\(searchText)\u{201D}")
                .foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.destination) { group in
            Section(group.destination.title) {
                ForEach(group.entries) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .lineLimit(2)
                        Text(entry.section)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Selection only changes once; clicking the result that
                    // is already selected shows its setting again.
                    .simultaneousGesture(TapGesture().onEnded {
                        if searchSelection == entry.id { choose(entry) }
                    })
                    .accessibilityElement(children: .combine)
                    .tag(entry.id)
                }
            }
        }
    }

    /// Opens a result's page and points at its setting.
    private func choose(_ entry: SettingsSearch.Entry) {
        destination = entry.destination
        SettingsHighlight.shared.reveal(entry.id)
    }

    private var dataTabTitle: String {
        issueCenter.issues.isEmpty ? "Data" : "Data (\(issueCenter.issues.count))"
    }

    private func sidebarTitle(for destination: SettingsDestination) -> String {
        destination == .data ? dataTabTitle : destination.title
    }

    private var currentDestination: SettingsDestination {
        destination ?? .general
    }

    private var activeProfile: TerminalProfile? {
        activeProfileID.flatMap { profiles.profile(withID: $0) }
    }

    @ViewBuilder
    private var detail: some View {
        switch currentDestination {
        case .general:
            GeneralSettingsView()
        case .links:
            LinksSettingsView()
        case .profiles:
            ProfilesSettingsView(activeProfileID: $activeProfileID)
        case .text, .window, .shell, .keyboard, .advanced:
            profileSettingsDetail(for: currentDestination)
        case .projects:
            ProjectsSettingsView()
        case .notifications:
            NotificationsSettingsView()
        case .updates:
            UpdatesSettingsView()
        case .data:
            DataRecoveryView(issueCenter: issueCenter, recovery: recovery)
        }
    }

    @ViewBuilder
    private func profileSettingsDetail(for destination: SettingsDestination) -> some View {
        if let section = ProfileSettingsSection(destination: destination),
           let profile = activeProfile {
            ProfileSettingsPage(section: section, profile: profile, update: updateActiveProfile)
        } else {
            ContentUnavailableView {
                Label("No Profile to Edit", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Create a profile before you change these settings.")
            } actions: {
                Button("Create Profile", action: createProfile)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button {
                    activeProfileID = profile.id
                } label: {
                    if profile.id == activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            Label(
                "Profile: \(activeProfile?.name ?? "None")",
                systemImage: "person.crop.circle"
            )
        }
        // Title and icon: the toolbar otherwise shows the icon alone, which
        // leaves no sign of which profile these pages are editing.
        .labelStyle(.titleAndIcon)
        .help("The profile these settings change")
        .disabled(profiles.profiles.isEmpty)
        .accessibilityLabel("Profile")
        .accessibilityValue(activeProfile?.name ?? "None")
    }

    private func repairActiveProfileSelection() {
        if let activeProfileID,
           profiles.profile(withID: activeProfileID) != nil {
            return
        }
        activeProfileID = profiles.profiles.isEmpty ? nil : profiles.defaultProfileID
    }

    private func createProfile() {
        var profile = profiles.defaultProfile
        profile.id = UUID()
        profile.name = uniqueProfileName(basedOn: "New Profile")
        do {
            try profiles.add(profile)
            activeProfileID = profile.id
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func uniqueProfileName(basedOn base: String) -> String {
        var name = base
        var number = 2
        while profiles.profile(named: name) != nil {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// Returns false when the change could not be stored, so callers that
    /// coordinate multi-step operations (theme forking) can roll back.
    private func updateActiveProfile(_ mutate: (inout TerminalProfile) -> Void) -> Bool {
        guard var profile = activeProfile else { return false }
        mutate(&profile)
        do {
            try profiles.update(profile)
            return true
        } catch {
            profileErrorMessage = error.localizedDescription
            return false
        }
    }

    private var profileErrorPresentation: Binding<Bool> {
        Binding(
            get: { profileErrorMessage != nil },
            set: { if !$0 { profileErrorMessage = nil } }
        )
    }
}

struct SettingsEscapeKeyHandler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView(coordinator: context.coordinator)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.window = nsView.window
    }

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class WindowReaderView: NSView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not available")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.window = window
        }
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var closeWindow: (NSWindow) -> Void = { window in
            window.performClose(nil)
        }
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window,
                      event.keyCode == 53,
                      event.window === window,
                      window.attachedSheet == nil else {
                    return event
                }

                if window.firstResponder is NSTextView {
                    // Some text is being edited. Do not close the window, let
                    // the text view handle the escape button.
                    return event
                }

                closeWindow(window)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case links
    case projects
    case notifications

    case profiles
    case text
    case window
    case shell
    case keyboard
    case advanced

    case updates
    case data

    var id: Self { self }

    /// The sidebar's sections. Scope decides the group, so a setting that
    /// applies everywhere is never on a page that edits one profile.
    enum Group: CaseIterable, Identifiable {
        case app
        case profile
        case maintenance

        var id: Self { self }

        var title: String? {
            switch self {
            case .app: return "Moo"
            case .profile: return "Profiles"
            case .maintenance: return nil
            }
        }

        var destinations: [SettingsDestination] {
            SettingsDestination.allCases.filter { $0.group == self }
        }
    }

    /// Where docs/SETTINGS.md documents this page on GitHub. The anchor is
    /// GitHub's slug for the page's heading; SettingsSearchTests checks that
    /// every page's anchor matches a heading in the doc.
    var documentationURL: URL {
        URL(string: "https://github.com/ventz/moo-mac-terminal/blob/main/docs/SETTINGS.md#\(documentationAnchor)")!
    }

    var documentationAnchor: String {
        switch self {
        case .general: return "general"
        case .links: return "links--markdown"
        case .projects: return "projects"
        case .notifications: return "notifications"
        case .profiles: return "profiles"
        case .text: return "appearance"
        case .window: return "window"
        case .shell: return "shell"
        case .keyboard: return "keyboard"
        case .advanced: return "advanced"
        case .updates: return "updates"
        case .data: return "data"
        }
    }

    var group: Group {
        switch self {
        case .general, .links, .projects, .notifications: return .app
        case .profiles, .text, .window, .shell, .keyboard, .advanced: return .profile
        case .updates, .data: return .maintenance
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .links: return "Links & Markdown"
        case .profiles: return "Profiles"
        case .projects: return "Projects"
        case .notifications: return "Notifications"
        case .updates: return "Updates"
        case .text: return "Appearance"
        case .window: return "Window"
        case .shell: return "Shell"
        case .keyboard: return "Keyboard"
        case .advanced: return "Advanced"
        case .data: return "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .links: return "link"
        case .profiles: return "person.2.badge.gearshape"
        case .projects: return "sidebar.left"
        case .notifications: return "bell.badge"
        case .updates: return "arrow.triangle.2.circlepath"
        case .text: return "textformat"
        case .window: return "macwindow"
        case .shell: return "terminal"
        case .keyboard: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        case .data: return "externaldrive.badge.checkmark"
        }
    }

    var isProfileDriven: Bool {
        switch self {
        case .text, .window, .shell, .keyboard, .advanced:
            return true
        case .general, .links, .profiles, .projects, .notifications, .updates, .data:
            return false
        }
    }
}

/// App-level (non-profile) settings, persisted via AppStorage
struct GeneralSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var windowGroups: WindowGroupStore
    @AppStorage("newTabsUseCurrentDirectory") private var newTabsUseCurrentDirectory = true
    @AppStorage("newTabsUseCurrentProfile") private var newTabsUseCurrentProfile = true
    @AppStorage("restoredRowsLimit") private var restoredRowsLimit = 1_000
    @AppStorage("startupMode") private var startupMode = "default"
    @AppStorage("startupProfileID") private var startupProfileID = ""
    @AppStorage("startupWindowGroupID") private var startupWindowGroupID = ""
    @AppStorage("useMetalRenderer") private var useMetalRenderer = true
    @AppStorage(WindowChromeDefaults.keepsTabStripOpaque) private var keepsTabStripOpaque = WindowChromeDefaults.keepsTabStripOpaqueByDefault
    @AppStorage(WorkspaceRestoreDefaults.restoresOnLaunch) private var restoresOnLaunch =
        WorkspaceRestoreDefaults.defaultRestoresOnLaunch
    /// Read through CommandDigitsChoice, which spans two keys; these only
    /// make the view redraw when either changes.
    @AppStorage(ProjectSidebarDefaults.commandDigitsTarget) private var commandDigitsTarget = CommandDigitsTarget.projects.rawValue
    @AppStorage(CommandDigitsChoice.selectsTabsKey) private var commandDigitsSelectTabs = true
    /// Read from defaults rather than held in @State, so an Import that
    /// applies settings while this window is open shows up here.
    @AppStorage(KeyboardDefaults.keyRepeatEnabled) private var keyRepeat = KeyboardDefaults.keyRepeatEnabledByDefault
    @AppStorage(SelectionDefaults.copyOnSelect) private var copyOnSelect = SelectionDefaults.copyOnSelectByDefault
    @AppStorage(TerminalImageDefaults.allowsLocalSources) private var imagesFromLocalSources =
        TerminalImageDefaults.allowsLocalSourcesByDefault
    @State private var errorMessage: String?

    @MainActor
    init() {
        self.init(windowGroups: AppModel.shared.windowGroups)
    }

    init(windowGroups: WindowGroupStore) {
        _windowGroups = ObservedObject(wrappedValue: windowGroups)
    }

    var body: some View {
        Form {
            Section("Startup") {
                Picker("Open:", selection: $startupMode) {
                    Text("A window with the default profile").tag("default")
                    Text("A window with this profile").tag("profile")
                    Text("A window group").tag("windowGroup")
                }
                .settingsAnchor(.general, "Open:")
                if startupMode == "profile" {
                    Picker("Profile:", selection: $startupProfileID) {
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                    .settingsAnchor(.general, "Profile:")
                } else if startupMode == "windowGroup" {
                    Picker("Window group:", selection: $startupWindowGroupID) {
                        Text("None").tag("")
                        ForEach(windowGroups.groups) { group in
                            Text(group.name).tag(group.id.uuidString)
                        }
                    }
                    .settingsAnchor(.general, "Window group:")
                }
                Toggle("Reopen workspaces, tabs, and splits on launch", isOn: $restoresOnLaunch)
                    .help("Shells start fresh in each pane's last directory. Scrollback is not kept.")
                    .settingsAnchor(.general, "Reopen workspaces, tabs, and splits on launch")
                Stepper(
                    "Restore up to \(restoredRowsLimit) rows of text when a saved session opens",
                    value: $restoredRowsLimit,
                    in: 0...100_000,
                    step: 100
                )
                .settingsAnchor(.general, "Restore rows of text when a saved session opens")
            }

            Section("New tabs and windows") {
                if profiles.profiles.isEmpty {
                    LabeledContent("Default profile:") {
                        Text("Built-in defaults")
                    }
                } else {
                    Picker("Default profile:", selection: defaultProfileBinding) {
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .settingsAnchor(.general, "Default profile:")
                    .help("Used for new windows, and wherever no explicit profile is chosen")
                }
                Toggle("Open new tabs in the current tab's directory", isOn: $newTabsUseCurrentDirectory)
                    .settingsAnchor(.general, "Open new tabs in the current tab's directory")
                Toggle("Open new tabs with the current window's profile", isOn: $newTabsUseCurrentProfile)
                    .settingsAnchor(.general, "Open new tabs with the current window's profile")
            }

            Section {
                Picker("⌘1–9 selects:", selection: commandDigitsBinding) {
                    ForEach(CommandDigitsChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .settingsAnchor(.general, "⌘1–9 selects:")
                Toggle("Repeat keys when held", isOn: keyRepeatBinding)
                    .settingsAnchor(.general, "Repeat keys when held")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("""
                    Projects are numbered in sidebar order; ⌘9 always selects the last.
                    Key repeat off: macOS's accent picker returns, but \u{2018}hjkl\u{2019} stop repeating in vim.
                    Per-profile keys, and a list of every shortcut, are under Profiles → Keyboard.
                    """)
            }

            Section {
                Toggle("Copy text when selected", isOn: $copyOnSelect)
                    .settingsAnchor(.general, "Copy text when selected")
            } header: {
                Text("Selection")
            } footer: {
                Text("""
                    On: dragging, double-clicking or triple-clicking text copies it, with no ⌘C.
                    Off: select, then ⌘C or right-click → Copy.
                    """)
            }

            Section {
                Toggle("Let programs show images from local files and shared memory", isOn: $imagesFromLocalSources)
                    .settingsAnchor(.general, "Let programs show images from local files and shared memory")
            } header: {
                Text("Images")
            } footer: {
                Text("""
                    On: programs can name a file or shared memory for an image, which Claude Code plugins such as intermission need.
                    Off: a file you cat or a host you ssh to cannot use that to check your files or delete shared memory.
                    Images sent inline always work. Applies to new tabs and splits.
                    """)
            }

            Section {
                Toggle("Keep the tab strip opaque in every profile", isOn: $keepsTabStripOpaque)
                    .settingsAnchor(.general, "Keep the tab strip opaque in every profile")
                Toggle("Draw with Metal", isOn: metalRendererBinding)
                    .settingsAnchor(.general, "Draw with Metal")
            } header: {
                Text("Window")
            } footer: {
                Text("""
                    Off: each profile decides whether its tab strip is opaque.
                    Colors, fonts and the title bar are set per profile, under Profiles → Appearance.
                    """)
            }
        }
        .formStyle(.grouped)
        .alert("Could Not Change Default Profile", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var commandDigitsBinding: Binding<CommandDigitsChoice> {
        Binding(
            get: {
                _ = (commandDigitsTarget, commandDigitsSelectTabs)
                return CommandDigitsChoice.current()
            },
            set: { $0.store() }
        )
    }

    /// App-wide rather than per-profile: macOS reads press-and-hold once, for
    /// the whole application, so a profile cannot own it.
    private var keyRepeatBinding: Binding<Bool> {
        Binding(
            get: { keyRepeat },
            set: { KeyRepeat.set(enabled: $0) }
        )
    }

    private var defaultProfileBinding: Binding<TerminalProfile.ID> {
        Binding(
            get: { profiles.defaultProfileID },
            set: { id in
                do {
                    try profiles.setDefault(id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var metalRendererBinding: Binding<Bool> {
        Binding(
            get: { useMetalRenderer },
            set: { enabled in
                useMetalRenderer = enabled
                TerminalSessionRegistry.shared.setUseMetalRenderer(enabled)
            }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

/// Where links open, Markdown previews, and browser tabs. App-wide.
struct LinksSettingsView: View {
    @AppStorage(LinkRoutingDefaults.opensLinksInApp) private var opensLinksInApp = true
    @AppStorage(MarkdownPreviewDefaults.followsTerminalTheme) private var markdownFollowsTheme = false
    @AppStorage(MarkdownPreviewDefaults.opensLinksInNewTab) private var markdownLinksOpenTabs = true
    @AppStorage(ContentBlockingDefaults.enabledKey) private var blocksAds = true

    var body: some View {
        Form {
            Section("From the terminal") {
                Toggle(isOn: $opensLinksInApp) {
                    labeled("⌘-click opens links and Markdown files in Moo tabs", notes: [
                        "On: ⌘-click a web address or a .md file to open it as a tab beside the terminal.",
                        "Off: it opens in your default browser or editor.",
                        "⌥⌘-click always uses the default app."
                    ])
                }
                .settingsAnchor(.links, "⌘-click opens links and Markdown files in Moo tabs")
            }
            Section("Markdown previews") {
                Toggle(isOn: $markdownFollowsTheme) {
                    labeled("Follow the terminal theme", notes: [
                        "On: a dark terminal theme gives a dark preview.",
                        "Off: previews are always light, with dark text."
                    ])
                }
                .settingsAnchor(.links, "Follow the terminal theme")
                Toggle(isOn: $markdownLinksOpenTabs) {
                    labeled("Open links to other Markdown files in new tabs", notes: [
                        "On: a link in a preview opens that file in a new tab; ⌘-click keeps it in the same tab.",
                        "Off: it opens in the same tab; ⌘-click opens a new tab.",
                        "⌘[ and ⌘] go back and forward either way."
                    ])
                }
                .settingsAnchor(.links, "Open links to other Markdown files in new tabs")
            }
            Section("Browser tabs") {
                Toggle(isOn: $blocksAds) {
                    labeled("Block ads and trackers", notes: [
                        "Uses EasyList and AdGuard's base and tracking-protection lists, through WebKit's content blocker.",
                        "Applies to open tabs on their next page load.",
                        "⇧⌘B opens a browser tab; ⌘L, ⌘[ / ⌘], ⌘R and ⌘F work as in Safari."
                    ])
                }
                .onChange(of: blocksAds) { _, enabled in
                    BrowserContentBlocking.shared.setEnabled(enabled)
                }
                .settingsAnchor(.links, "Block ads and trackers")
            }
        }
        .formStyle(.grouped)
    }

    /// A toggle's title with its explanation beneath, in the same row, so the
    /// form draws one line between settings and none inside a setting. One
    /// sentence per line, On before Off, so a note can be read at a glance.
    private func labeled(_ title: String, notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(notes, id: \.self) { line in
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview("Settings") {
    SettingsView(
        issueCenter: SettingsPreviewData.issueCenter,
        recovery: SettingsPreviewData.recovery
    )
    .environmentObject(SettingsPreviewData.profiles)
    .environmentObject(SettingsPreviewData.themes)
    .environmentObject(SettingsPreviewData.themeIndex)
    .defaultAppStorage(SettingsPreviewData.defaults)
    .frame(width: 960, height: 640)
}

#Preview("General") {
    GeneralSettingsView(windowGroups: SettingsPreviewData.windowGroups)
        .environmentObject(SettingsPreviewData.profiles)
        .defaultAppStorage(SettingsPreviewData.defaults)
        .frame(width: 640, height: 520)
}
