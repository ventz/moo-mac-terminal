//
//  ContentView.swift
//  Moo
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Binding var document: TerminalDocument
    /// nil for untitled windows; document metadata is only persisted for
    /// file-backed sessions so that closing an untitled window never
    /// triggers a save prompt
    var fileURL: URL?
    /// The pane tree shown when no workspace is selected — the plain terminal
    /// this app has always opened with.
    @State private var fallbackWorkspace = TerminalPaneWorkspace(
        startsProcesses: ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    )
    @State private var runtime = ProjectRuntime.shared
    /// This window's own workspace selection. Not the runtime's: two windows
    /// reading one global selection fought over the same terminal views.
    @State private var scope = WindowScope()
    /// The sidebar width when a resize drag began, so the drag is absolute
    /// rather than accumulating rounding error per frame.
    @State private var dragStartWidth: Double?
    @State private var isHoveringResizeHandle = false
    @State private var didAttemptInitialProject = false

    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var themeIndex: ThemeCatalogIndex
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.displayScale) private var displayScale

    /// This window's sidebar, not the app's: cmd+B in one window leaves the
    /// others as they were.
    private var sidebarIsVisible: Bool { scope.isSidebarVisible }
    @AppStorage(ProjectSidebarDefaults.width) private var sidebarWidth = ProjectSidebarDefaults.defaultWidth
    @AppStorage(ProjectSidebarDefaults.showsStatus) private var showsStatus = true
    @AppStorage(ProjectSidebarDefaults.showsBranch) private var showsBranch = true
    @AppStorage(ProjectSidebarDefaults.showsPath) private var showsPath = true
    @AppStorage(ProjectSidebarDefaults.showsAccent) private var showsAccent = true
    @AppStorage(WindowChromeDefaults.keepsTabStripOpaque) private var keepsTabStripOpaque = WindowChromeDefaults.keepsTabStripOpaqueByDefault

    /// The pane tree the terminal host shows: the selected workspace's active
    /// terminal tab — or, while a web tab is selected, the terminal tab that
    /// was most recently on screen, kept attached but hidden so switching
    /// back is instant. Nil when the workspace has no terminal tab at all.
    private var terminalWorkspace: TerminalPaneWorkspace? {
        guard let session = scope.session else { return fallbackWorkspace }
        return session.mostRecentTerminalTab?.panes
    }

    /// The pane tree the window chrome and the terminal commands follow.
    /// Never attached when it is the fallback for a web-only workspace, so it
    /// starts no shell.
    private var workspace: TerminalPaneWorkspace {
        terminalWorkspace ?? fallbackWorkspace
    }

    /// The web tab on screen, if the selected tab is one.
    private var selectedWebContent: (any WebTabContent)? {
        scope.session?.selectedTab?.web
    }

    private var showsTerminal: Bool {
        selectedWebContent == nil
    }

    /// Changes whenever a different tab lands on screen, in any workspace.
    private var onScreenTabKey: String {
        let project = scope.selectedProjectID?.uuidString ?? "-"
        let tab = scope.session?.selectedTabID?.uuidString ?? "-"
        return project + "/" + tab
    }

    /// True for the single render pass before the first project is chosen or
    /// created. The fallback terminal must not attach then, or it would start
    /// a shell belonging to no project that stays running for the life of the
    /// app. Once the attempt has been made it stops gating, so a store that
    /// cannot be written still gets a working terminal.
    private var isAwaitingInitialProject: Bool {
        scope.selectedProjectID == nil && !didAttemptInitialProject
    }

    private var rootController: TerminalSessionController? {
        workspace.controllers.first
    }

    /// The controller the window chrome follows. Focus is briefly nil while a
    /// pane is torn down or before the first pane is built; falling back to the
    /// root pane keeps the titlebar on the profile theme instead of flashing
    /// the built-in dark fallback.
    private var chromeController: TerminalSessionController? {
        workspace.focusedController ?? rootController
    }

    private var windowTheme: TerminalTheme {
        chromeController?.effectiveTheme ?? .fallback
    }

    private var usesThemeWindowChrome: Bool {
        chromeController?.profile.useThemeColorsForWindowChrome ?? true
    }

    private var chromeBackgroundOpacity: Double {
        chromeController?.effectiveBackgroundOpacity ?? 1
    }

    /// The tab strip and the sidebar each follow the terminal's opacity unless
    /// pinned opaque, which keeps their text legible over a busy desktop while
    /// the terminal stays translucent. The tab strip can also be pinned for
    /// every profile at once in Settings → General.
    private var tabStripBackgroundOpacity: Double {
        WindowChromeOpacity.tabStrip(
            terminalOpacity: chromeBackgroundOpacity,
            profilePinsOpaque: chromeController?.profile.keepsTabStripOpaque == true,
            appPinsOpaque: keepsTabStripOpaque
        )
    }

    private var sidebarBackgroundOpacity: Double {
        chromeController?.profile.keepsSidebarOpaque == true ? 1 : chromeBackgroundOpacity
    }

    private var rowVisibility: ProjectRowVisibility {
        ProjectRowVisibility(
            showsStatus: showsStatus,
            showsBranch: showsBranch,
            showsPath: showsPath,
            showsAccent: showsAccent
        )
    }

    /// The sidebar animates its width to zero rather than being inserted and
    /// removed, so SwiftUI never tears down a view sitting beside a live
    /// terminal. The terminal container itself is never conditionally rendered.
    var body: some View {
        // Tabs get a full-width row directly under the titlebar, exactly where
        // macOS Terminal puts them — and, like Terminal, only once there is
        // more than one tab. A strip showing a single tab is pure overhead.
        VStack(spacing: 0) {
            if let session = scope.session, session.tabs.count > 1 {
                WorkspaceTabBar(
                    session: session,
                    background: tabStripBackground,
                    foreground: tabStripForeground,
                    // The picker themes the focused terminal; a web tab has none.
                    showThemePicker: showsTerminal
                        ? { workspace.focusedController?.showThemePicker = true }
                        : nil
                )
                // No divider. Hiding one with .opacity(0) still left the
                // point of height it occupied, and on a transparent window
                // that gap showed the desktop through as a pale line. The
                // strip and the terminal share the theme background, so there
                // is nothing to separate.
            }
            HStack(spacing: 0) {
                ProjectSidebarView(
                    store: projects,
                    runtime: runtime,
                    scope: scope,
                    visibility: rowVisibility,
                    background: sidebarBackground
                )
                .frame(width: sidebarIsVisible ? sidebarWidth : 0)
                .clipped()
                .opacity(sidebarIsVisible ? 1 : 0)
                .allowsHitTesting(sidebarIsVisible)
                .accessibilityHidden(!sidebarIsVisible)
                .overlay(alignment: .trailing) {
                    if sidebarIsVisible {
                        sidebarEdge
                    }
                }
                // An overlay, not a column: reserving width for the grip put a
                // visible gutter between the panes. Applied after .clipped()
                // so it is not cut off, and offset to straddle the edge.
                .overlay(alignment: .trailing) {
                    if sidebarIsVisible {
                        sidebarResizeHandle.offset(x: 4)
                    }
                }

                // A closing window shows nothing: see ProjectRuntime.windowWillClose.
                if isAwaitingInitialProject || scope.isClosed {
                    Color.clear
                } else {
                    terminalArea
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sidebarIsVisible)
        // Must live on the outer view: the terminal area is not rendered until
        // a workspace is selected, so selecting from there would never run.
        .onAppear {
            runtime.register(scope)
            selectInitialProjectIfNeeded()
        }
        .onDisappear { runtime.unregister(scope) }
        .onChange(of: projects.projects) { _, _ in
            selectInitialProjectIfNeeded()
        }
    }

    /// A single-pixel rule on the sidebar's edge. The darkened sidebar alone
    /// does not separate it from a dark terminal, or from anything at all when
    /// the chrome is not themed. An overlay, so it takes no width from either
    /// pane and leaves no gap for a transparent window to show through.
    private var sidebarEdge: some View {
        Rectangle()
            .fill(sidebarEdgeColor)
            .frame(width: 1 / max(displayScale, 1))
            .allowsHitTesting(false)
    }

    /// Derived from the theme's foreground so the rule is equally faint on
    /// light and dark themes; the system separator otherwise.
    private var sidebarEdgeColor: Color {
        guard usesThemeWindowChrome else {
            return Color(nsColor: .separatorColor)
        }
        return windowTheme.foreground.swiftUIColor.opacity(0.15)
    }

    /// The divider doubles as the resize grip. It is drawn at the configured
    /// border width but claims a wider hit area, because a one-point target is
    /// not something a person can reliably grab.
    private var sidebarResizeHandle: some View {
        // Purely a grip; sidebarEdge draws the visible rule.
        Color.clear
            .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { inside in
            // A resize cursor is the only affordance that this thin strip is
            // draggable at all. The flag keeps push and pop balanced: a
            // repeated enter or a missed exit would otherwise leave the resize
            // cursor stuck over the whole app.
            guard inside != isHoveringResizeHandle else { return }
            isHoveringResizeHandle = inside
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = sidebarWidth
                    }
                    let proposed = (dragStartWidth ?? sidebarWidth) + value.translation.width
                    sidebarWidth = min(
                        max(proposed, ProjectSidebarDefaults.minimumWidth),
                        ProjectSidebarDefaults.maximumWidth
                    )
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }

    /// The strip abuts the terminal, so it follows the terminal theme when the
    /// profile opts into themed chrome, and the system chrome otherwise.
    private var tabStripBackground: Color {
        guard usesThemeWindowChrome else {
            return Color(nsColor: .windowBackgroundColor)
        }
        // Carries the profile's background opacity, so the chrome is exactly
        // as transparent as the terminal it sits against. A solid strip over a
        // translucent window reads as a patch stuck on top of it.
        return windowTheme.background.swiftUIColor.opacity(tabStripBackgroundOpacity)
    }

    /// The sidebar sits beside the terminal rather than behind text, so it is
    /// darkened a little to set it apart — and it takes the same opacity, so
    /// the whole window is uniformly transparent — unless the profile pins it
    /// opaque.
    private var sidebarBackground: Color {
        guard usesThemeWindowChrome else {
            return Color(nsColor: .underPageBackgroundColor)
        }
        return Self.darkened(windowTheme.background, by: 0.35)
            .opacity(sidebarBackgroundOpacity)
    }

    /// Blends a theme colour toward black. Works for light themes too, where
    /// it reads as a shade rather than a black bar.
    private static func darkened(_ color: ProfileColor, by amount: Double) -> Color {
        let scale = max(0, 1 - amount)
        return Color(
            red: Double(color.red) / 65535 * scale,
            green: Double(color.green) / 65535 * scale,
            blue: Double(color.blue) / 65535 * scale
        )
    }

    private var tabStripForeground: Color {
        usesThemeWindowChrome
            ? windowTheme.foreground.swiftUIColor
            : Color(nsColor: .labelColor)
    }

    private var selectedProject: Project? {
        projects.project(withID: scope.selectedProjectID)
    }

    private var terminalArea: some View {
        // Note: no .id() on the pane tree. Re-identifying the representable
        // would make SwiftUI build a new host view and discard the old one;
        // instead the same host is handed a different tree and re-attaches the
        // terminals, so switching workspaces never restarts a shell.
        //
        // The terminal host and the web host are both always mounted, one
        // over the other, and a tab switch only changes which is visible and
        // takes clicks. Neither is ever torn down by selecting the other.
        ZStack {
            if let terminalWorkspace {
                TerminalPaneContainer(
                    workspace: terminalWorkspace,
                    document: document,
                    revision: terminalWorkspace.revision
                )
                .opacity(showsTerminal ? 1 : 0)
                .allowsHitTesting(showsTerminal)
                .accessibilityHidden(!showsTerminal)
            }
            WebTabContainer(content: selectedWebContent)
                .opacity(showsTerminal ? 0 : 1)
                .allowsHitTesting(!showsTerminal)
                .accessibilityHidden(showsTerminal)
        }
            .overlay(alignment: .bottomTrailing) {
                SecureInputBadge()
            }
            .overlay {
                if scope.isPaletteVisible {
                    CommandPaletteView(
                        scope: scope,
                        controller: showsTerminal ? workspace.focusedController : nil,
                        projects: projects.projects
                    )
                }
            }
            .onChange(of: onScreenTabKey) {
                // The palette read the pane that was on screen; it would act
                // on the wrong one now.
                scope.isPaletteVisible = false
                focusOnScreenTab()
            }
            .background(WindowTabbingConfigurator(
                theme: usesThemeWindowChrome ? windowTheme : nil,
                backgroundOpacity: chromeBackgroundOpacity,
                sizingProfile: chromeController?.profile ?? profiles.defaultProfile,
                scope: scope
            ))
            .preferredColorScheme(
                usesThemeWindowChrome ? (windowTheme.isDark ? .dark : .light) : nil
            )
            .sheet(isPresented: themePickerBinding) {
                if let controller = workspace.focusedController {
                    VStack(spacing: 0) {
                        ThemePickerPopover(
                            controller: controller,
                            themes: themes,
                            themeIndex: themeIndex,
                            profiles: profiles
                        )
                        Divider()
                        HStack {
                            Spacer()
                            Button("Done") { controller.showThemePicker = false }
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(10)
                    }
                }
            }
            .onAppear(perform: configureBufferPersistence)
            .onChange(of: fileURL) {
                configureBufferPersistence()
            }
            .onChange(of: rootController?.id) {
                configureBufferPersistence()
            }
            .onChange(of: rootController?.themeOverride) { _, newValue in
                if fileURL != nil && document.themeOverride != newValue {
                    document.themeOverride = newValue
                }
            }
            .onChange(of: rootController?.profile.id) { _, newValue in
                if fileURL != nil, let newValue, document.profileID != newValue {
                    document.profileID = newValue
                }
            }
            .onChange(of: profiles.profiles) {
                for controller in workspace.controllers {
                    if let stored = profiles.profile(withID: controller.profile.id),
                       stored != controller.profile {
                        controller.applyProfile(stored)
                    }
                }
            }
            .onChange(of: themes.themes) {
                // A user theme was edited/imported: re-resolve colors
                for controller in workspace.controllers {
                    controller.applyAppearance()
                }
            }
    }

    private var themePickerBinding: Binding<Bool> {
        Binding(
            get: { workspace.focusedController?.showThemePicker ?? false },
            set: { workspace.focusedController?.showThemePicker = $0 }
        )
    }

    /// Opens straight into a workspace when one exists, so the launch terminal
    /// does not linger outside every workspace as an extra shell.
    private func selectInitialProjectIfNeeded() {
        guard scope.selectedProjectID == nil, !scope.isClosed else { return }
        defer { didAttemptInitialProject = true }

        // Relaunching: this window takes the next one from the last run.
        if let restored = runtime.takeRestoredWindow(existing: Set(projects.projects.map(\.id))) {
            scope.isSidebarVisible = restored.showsSidebar
            if let projectID = restored.projectID {
                runtime.select(projectID: projectID, in: scope)
                return
            }
        }

        let remembered = UserDefaults.standard
            .string(forKey: ProjectSidebarDefaults.selectedProjectID)
            .flatMap(UUID.init(uuidString:))

        // A second window must not adopt a workspace the first is showing, so
        // the remembered one is only used when it is free. Otherwise take the
        // first unshown workspace, and failing that create one — which is what
        // makes cmd+N a genuinely new window rather than a clone.
        let candidate = projects.project(withID: remembered).flatMap {
            runtime.scope(showing: $0.id) == nil ? $0 : nil
        } ?? runtime.firstUnshownProject(among: projects.projects)

        if let project = candidate {
            runtime.select(projectID: project.id, in: scope)
            return
        }

        // Nothing to restore: this is a first run, or every project was
        // removed. Rather than opening onto an empty sidebar explaining what
        // projects are, start inside one. It is auto-named, so it shows the
        // directory the terminal lands in until it is renamed.
        guard let created = try? projects.addAutoNamed() else {
            // The store is read-only (a recovery issue). Fall back to a plain
            // terminal instead of leaving a blank window.
            return
        }
        runtime.select(projectID: created.id, in: scope)
    }

    /// Hands keyboard focus to whatever just came on screen. Deferred a turn
    /// of the run loop: AppKit needs the newly attached view in the window
    /// first, and asking earlier either does nothing or lands focus on the
    /// view being hidden — the "keystrokes go to the wrong tab" bug.
    private func focusOnScreenTab() {
        let web = selectedWebContent
        let terminal = workspace.focusedController
        DispatchQueue.main.async {
            if let web {
                web.focus()
            } else {
                terminal?.requestFocus()
            }
        }
    }

    private func configureBufferPersistence() {
        guard let controller = rootController else { return }
        guard fileURL != nil else {
            controller.bufferSnapshotHandler = nil
            return
        }
        controller.bufferSnapshotHandler = { content in
            if document.content != content {
                document.content = content
            }
        }
    }
}

/// The per-window theme picker: applies the selection to this session only,
/// with escape hatches to make it the profile-wide theme or reset
struct ThemePickerPopover: View {
    var controller: TerminalSessionController
    @ObservedObject var themes: ThemeStore
    @ObservedObject var themeIndex: ThemeCatalogIndex
    @ObservedObject var profiles: ProfileStore
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            ThemeBrowserView(themes: themes,
                             themeIndex: themeIndex,
                             selectedThemeName: controller.effectiveTheme.name) { theme in
                controller.applyThemeOverride(theme.name)
            }
                             .padding(.top)
                             .frame(minWidth: 520, minHeight: 420, maxHeight: 500)
            Divider()
            HStack {
                Button("Reset to Profile Theme") {
                    controller.applyThemeOverride(nil)
                }
                .disabled(controller.themeOverride == nil)
                Spacer()
                Button("Use for All Windows") {
                    var profile = controller.profile
                    profile.themeName = controller.effectiveTheme.name
                    do {
                        try profiles.update(profile)
                        controller.applyThemeOverride(nil)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .help("Makes this theme the profile default, updating every window that uses the profile")
            }
            .padding(10)
        }
        .alert("Could Not Change Profile Theme", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }
}

struct WindowTabbingConfigurator: NSViewRepresentable {
    let theme: TerminalTheme?
    var backgroundOpacity: Double = 1
    /// The profile a new window is sized from when it has no saved frame.
    var sizingProfile: TerminalProfile?
    /// Bound so the runtime can tell which window is key, and so selecting a
    /// workspace another window holds can bring that window forward.
    var scope: WindowScope?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            scope?.window = window
            window.tabbingIdentifier = "TerminalDocument"
            window.tabbingMode = .preferred
            // The tab strip occupies the titlebar and already names the active
            // terminal, so the window title would only repeat it.
            // A normal titlebar. macOS Terminal keeps its title row and puts
            // tabs in a row of their own below it, so Moo does the same.
            if let sizingProfile {
                TerminalWindowSizeStore.shared.configureNewWindow(
                    window,
                    profileContentSize: TerminalProfileWindowSizer.contentSize(for: sizingProfile)
                )
            } else {
                TerminalWindowSizeStore.shared.configure(window)
            }
            TerminalWindowAppearance.apply(
                theme: theme,
                backgroundOpacity: backgroundOpacity,
                to: window
            )
        }
    }
}

#Preview("Terminal Window") {
    ContentView(
        document: .constant(TerminalDocument(
            content: "ventz@mac moo % swift test\n\rAll tests passed.\r\n"
        ))
    )
    .environmentObject(SettingsPreviewData.profiles)
    .environmentObject(SettingsPreviewData.themes)
    .environmentObject(SettingsPreviewData.themeIndex)
    .environmentObject(SettingsPreviewData.projects)
    .frame(width: 900, height: 560)
}

#Preview("Theme Picker") {
    @Previewable @State var controller = TerminalSessionController(startsProcess: false)

    ThemePickerPopover(
        controller: controller,
        themes: SettingsPreviewData.themes,
        themeIndex: SettingsPreviewData.themeIndex,
        profiles: SettingsPreviewData.profiles
    )
}
