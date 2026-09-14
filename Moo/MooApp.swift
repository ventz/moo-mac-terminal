//
//  MooApp.swift
//  Moo
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftTerm
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didEnsureStartupWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        // Before any window appears: each takes its workspace from the last
        // run as it opens. A chosen window group wins over restore.
        let defaults = UserDefaults.standard
        ProjectRuntime.shared.beginRestore(
            from: AppModel.shared.workspaceRestore,
            restoring: WorkspaceRestoreDefaults.isEnabled
                && defaults.string(forKey: "startupMode") != "windowGroup"
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        _ = SecureKeyboardEntry.shared
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        AttentionCenter.shared.installBannerHandling()
        AttentionStatusItem.shared.install()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !didEnsureStartupWindow else { return }
        didEnsureStartupWindow = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        // Wait until SwiftUI restores its document scenes. A document can
        // exist before its terminal session registers.
        DispatchQueue.main.async { [weak self] in
            let hasDocument = !NSDocumentController.shared.documents.isEmpty
            let hasTerminalWindow = NSApp.windows.contains { window in
                !TerminalSessionRegistry.shared.controllers(for: window).isEmpty
            }
            guard !hasDocument, !hasTerminalWindow else { return }
            self?.openStartupWindow()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        WindowOpener.openWindow(spec: LaunchSpec())
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Includes workspaces that are not currently displayed: their shells
        // are still running, so quitting still needs to warn about them.
        let hasLiveProcess = sender.windows.contains { window in
            TerminalSessionRegistry.shared.controllers(for: window)
                .contains(where: TerminalClosePolicy.requiresConfirmation)
        } || ProjectRuntime.shared.allControllers
            .contains(where: TerminalClosePolicy.requiresConfirmation)
        guard hasLiveProcess else {
            ProjectRuntime.shared.saveForQuit()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit and terminate running processes?"
        alert.informativeText = "A process is still running."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        ProjectRuntime.shared.saveForQuit()
        return .terminateNow
    }

    func applicationDidResignActive(_ notification: Notification) {
        // No flagsChanged arrives once the app is inactive, so a Command held
        // during a cmd+tab would otherwise leave the sidebar badges stuck on.
        ModifierMonitor.shared.clear()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureKeyboardEntry.shared.disableForTermination()
    }

    private func openStartupWindow() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "startupMode") == "windowGroup",
           let rawID = defaults.string(forKey: "startupWindowGroupID"),
           let id = UUID(uuidString: rawID),
           let group = AppModel.shared.windowGroups.group(withID: id),
           AppModel.shared.windowGroups.open(group) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var spec = LaunchSpec()
        if defaults.string(forKey: "startupMode") == "profile",
           let rawID = defaults.string(forKey: "startupProfileID") {
            spec.profileID = UUID(uuidString: rawID)
        }
        // Read before opening: each window takes a saved one as it appears.
        let restoredWindows = ProjectRuntime.shared.restorableWindowCount(
            existing: Set(AppModel.shared.projects.projects.map(\.id))
        )
        WindowOpener.openWindow(spec: spec, initialFrame: .saved)
        for _ in 1..<max(restoredWindows, 1) {
            WindowOpener.openWindow(spec: LaunchSpec())
        }
    }
}

/// macOS Secure Keyboard Entry, which keeps other processes from reading
/// keystrokes. On when the user turns it on, and — like Ghostty — by itself
/// while the focused pane reads a password.
///
/// This is the only place that calls Enable/DisableSecureEventInput. The OS
/// counts enables per process, so a second Enable, or a missed Disable,
/// would leave every app's typing protected until Moo quits.
@Observable
@MainActor
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    /// How often the key pane's pty is checked for a password prompt: one
    /// tcgetattr, only while Moo is active and the setting is on. Never on
    /// SwiftTerm's parse thread.
    static let promptCheckInterval: TimeInterval = 0.25

    /// The user's own switch.
    var isEnabled = false {
        didSet {
            defaults.set(isEnabled, forKey: AppSettings.secureKeyboardEntry)
            applyState()
        }
    }

    /// Turn it on automatically while the focused pane reads a password.
    var protectsPasswordPrompts = true {
        didSet {
            defaults.set(protectsPasswordPrompts, forKey: AppSettings.secureKeyboardEntryAtPasswordPrompts)
            refreshPromptWatching()
        }
    }

    /// A password prompt is holding it on right now.
    private(set) var isProtectingPrompt = false
    /// Secure input is on because of Moo, for either reason.
    private(set) var isActive = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enableInput: () -> Bool
    @ObservationIgnored private let disableInput: () -> Void
    @ObservationIgnored private let focusedPaneIsAtPasswordPrompt: () -> Bool
    @ObservationIgnored private let isAppActive: () -> Bool
    @ObservationIgnored private let watchesWithTimer: Bool
    @ObservationIgnored private var promptTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The key pane reads a password, whether or not enabling worked.
    @ObservationIgnored private var promptDetected = false
    @ObservationIgnored private var isTerminated = false

    private convenience init() {
        self.init(
            defaults: .standard,
            enableInput: { EnableSecureEventInput() == noErr },
            disableInput: { DisableSecureEventInput() },
            focusedPaneIsAtPasswordPrompt: SecureKeyboardEntry.keyPaneIsAtPasswordPrompt,
            isAppActive: { NSApp?.isActive ?? false },
            watchesWithTimer: true
        )
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SecureKeyboardEntry.shared.refreshPromptWatching() }
            })
        }
    }

    init(
        defaults: UserDefaults,
        enableInput: @escaping () -> Bool,
        disableInput: @escaping () -> Void,
        focusedPaneIsAtPasswordPrompt: @escaping () -> Bool,
        isAppActive: @escaping () -> Bool,
        watchesWithTimer: Bool = false
    ) {
        self.defaults = defaults
        self.enableInput = enableInput
        self.disableInput = disableInput
        self.focusedPaneIsAtPasswordPrompt = focusedPaneIsAtPasswordPrompt
        self.isAppActive = isAppActive
        self.watchesWithTimer = watchesWithTimer
        isEnabled = defaults.bool(forKey: AppSettings.secureKeyboardEntry)
        protectsPasswordPrompts = defaults.object(forKey: AppSettings.secureKeyboardEntryAtPasswordPrompts) as? Bool ?? true
        applyState()
        refreshPromptWatching()
    }

    /// Picks up both settings after an import or a restore wrote them.
    func reloadFromDefaults() {
        isEnabled = defaults.bool(forKey: AppSettings.secureKeyboardEntry)
        protectsPasswordPrompts = defaults.object(forKey: AppSettings.secureKeyboardEntryAtPasswordPrompts) as? Bool ?? true
    }

    func disableForTermination() {
        isTerminated = true
        promptTimer?.invalidate()
        promptTimer = nil
        guard isActive else { return }
        disableInput()
        isActive = false
        isProtectingPrompt = false
    }

    /// Starts or stops the prompt check as the app activates, deactivates or
    /// the setting changes, then checks once.
    func refreshPromptWatching() {
        guard !isTerminated else { return }
        let watches = protectsPasswordPrompts && isAppActive()
        if watches, watchesWithTimer, promptTimer == nil {
            let timer = Timer(timeInterval: Self.promptCheckInterval, repeats: true) { _ in
                MainActor.assumeIsolated { SecureKeyboardEntry.shared.checkPasswordPrompt() }
            }
            // Common modes: keep checking while a menu is open or a window resizes.
            RunLoop.main.add(timer, forMode: .common)
            promptTimer = timer
        } else if !watches {
            promptTimer?.invalidate()
            promptTimer = nil
        }
        checkPasswordPrompt()
    }

    /// Cheap enough to call from output arriving: one tcgetattr.
    func checkPasswordPrompt() {
        guard !isTerminated else { return }
        promptDetected = protectsPasswordPrompts && isAppActive() && focusedPaneIsAtPasswordPrompt()
        applyState()
    }

    /// Idempotent: Enable only while off, Disable only while on, so the OS
    /// count never passes one. A failed Enable is retried on the next check.
    private func applyState() {
        guard !isTerminated else { return }
        // The manual switch applies only while Moo is frontmost, as Apple
        // recommends: held in the background it blocks other apps' hotkeys.
        let desired = (isEnabled && isAppActive()) || promptDetected
        if desired, !isActive {
            if enableInput() {
                isActive = true
            } else if isEnabled, !promptDetected {
                isEnabled = false
            }
        } else if !desired, isActive {
            disableInput()
            isActive = false
        }
        // The badge claims protection only when it really is on.
        let protecting = promptDetected && isActive
        if isProtectingPrompt != protecting {
            isProtectingPrompt = protecting
        }
    }

    /// The first responder of the key window, if it is a terminal whose pty
    /// has echo off with line editing on.
    static func keyPaneIsAtPasswordPrompt() -> Bool {
        guard let window = NSApp.keyWindow,
              let controller = TerminalSessionRegistry.shared.controller(for: window),
              let terminal = controller.terminal,
              window.firstResponder === terminal,
              let process = terminal.process, process.running else {
            return false
        }
        return TerminalProcessInspector.isPasswordPrompt(ptyDescriptor: process.childfd)
    }
}

/// Shown while a password prompt holds Secure Keyboard Entry on, so it is
/// clear when typing is protected and when it is not. The manual switch
/// has its checkmark in the Terminal menu and no badge.
struct SecureInputBadge: View {
    @State private var secureKeyboardEntry = SecureKeyboardEntry.shared
    /// Only the key window holds the prompt being protected.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if secureKeyboardEntry.isProtectingPrompt, controlActiveState == .key {
            Label("Secure Input", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
                .help("Other apps cannot read your keystrokes while this password prompt is open")
                .accessibilityLabel("Secure keyboard entry is on for this password prompt")
        }
    }
}

struct NewItemCommands: Commands {
    // The key window's sidebar, read through the runtime so the menu title and
    // behavior follow both a toggle and a switch to another window.
    private var sidebarIsVisible: Bool { ProjectRuntime.shared.keyScope.isSidebarVisible }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // cmd+N follows what is on screen: a new project while the
            // workspace sidebar is open, a new window otherwise.
            Button(sidebarIsVisible ? "New Project" : "New Window") {
                if sidebarIsVisible {
                    ProjectCommandActions.addProjectWithoutPrompting(
                        store: AppModel.shared.projects
                    )
                } else {
                    WindowOpener.openWindow(spec: LaunchSpec())
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Window") {
                WindowOpener.openWindow(spec: LaunchSpec())
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("New Tab") {
                // Tabs belong to the selected workspace. With no workspace
                // selected this is still a native tab, inheriting working
                // directory and profile per the General settings.
                if let session = ProjectRuntime.shared.selectedSession {
                    session.addTab()
                    ProjectRuntime.shared.invalidate()
                } else {
                    WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec())
                }
            }
            .keyboardShortcut("t", modifiers: [.command])
        }
    }
}

struct TabSelectionCommands: Commands {
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            // cmd+1...9 has a single owner. Which thing it selects is a
            // preference, because projects and tabs cannot both claim it.
            Menu(digitsTarget == .projects ? "Select Project" : "Select Tab") {
                ForEach(1...8, id: \.self) { number in
                    Button(digitsTarget == .projects
                           ? "Select Project \(number)"
                           : "Select Tab \(number)") {
                        selectByDigit(index: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command])
                }
                Divider()
                Button(digitsTarget == .projects ? "Select Last Project" : "Select Last Tab") {
                    selectLastByDigit()
                }
                .keyboardShortcut("9", modifiers: [.command])
            }

            Divider()

            // Tabs belong to the selected workspace, so these cycle within it.
            Button("Show Previous Tab") {
                ProjectRuntime.shared.selectedSession?.selectPreviousTab()
                ProjectRuntime.shared.invalidate()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!hasMultipleTabs)

            Button("Show Next Tab") {
                ProjectRuntime.shared.selectedSession?.selectNextTab()
                ProjectRuntime.shared.invalidate()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!hasMultipleTabs)

            Divider()

            Button("Select Previous Split") {
                commandState.controller?.workspace?.selectPreviousSplit()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!hasMultipleSplits)

            Button("Select Next Split") {
                commandState.controller?.workspace?.selectNextSplit()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!hasMultipleSplits)
        }
    }

    private var hasMultipleSplits: Bool {
        (commandState.controller?.workspace?.paneCount ?? 0) > 1
    }

    private var hasMultipleTabs: Bool {
        (ProjectRuntime.shared.selectedSession?.tabs.count ?? 0) > 1
    }

    private var digitsTarget: CommandDigitsTarget {
        CommandDigitsTarget.current
    }

    private func selectByDigit(index: Int) {
        if digitsTarget == .projects {
            ProjectSelection.selectProject(at: index)
        } else {
            selectTab(at: index)
        }
    }

    private func selectLastByDigit() {
        if digitsTarget == .projects {
            ProjectSelection.selectLastProject()
        } else {
            selectLastTab()
        }
    }

    private func selectTab(at index: Int) {
        guard UserDefaults.standard.bool(forKey: "useCommandDigitsForTabs"),
              let tabGroup = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup,
              tabGroup.windows.indices.contains(index) else {
            return
        }
        tabGroup.selectedWindow = tabGroup.windows[index]
    }

    private func selectLastTab() {
        guard UserDefaults.standard.bool(forKey: "useCommandDigitsForTabs"),
              let tabGroup = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup,
              let lastWindow = tabGroup.windows.last else {
            return
        }
        tabGroup.selectedWindow = lastWindow
    }
}

struct SplitCommands: Commands {
    @State private var commandState = TerminalCommandState()

    private var workspace: TerminalPaneWorkspace? {
        commandState.controller?.workspace
    }

    private var hasMultipleSplits: Bool {
        (workspace?.paneCount ?? 0) > 1
    }

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Select Split") {
                Button("Select Split Above") {
                    workspace?.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Below") {
                    workspace?.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Left") {
                    workspace?.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Right") {
                    workspace?.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)
            }

            Menu("Resize Split") {
                Button("Equalize Split") {
                    workspace?.equalizeSplits()
                }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Divider()

                Button("Move Divider Up") {
                    workspace?.moveDivider(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Down") {
                    workspace?.moveDivider(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Left") {
                    workspace?.moveDivider(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Right") {
                    workspace?.moveDivider(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)
            }
        }
    }
}

struct TerminalCommands: Commands {
    @State private var commandState = TerminalCommandState()
    @State private var secureKeyboardEntry = SecureKeyboardEntry.shared
    @State private var runtime = ProjectRuntime.shared

    private var controller: TerminalSessionController? {
        commandState.controller
    }

    private var closesTabRatherThanPane: Bool {
        guard ProjectRuntime.shared.selectedSession != nil else { return false }
        return (controller?.workspace?.paneCount ?? 1) <= 1
    }

    private func closeCurrent() {
        // A web tab has no panes. The focused controller still points at the
        // hidden terminal tab behind it, so without this cmd+W would close a
        // split the user cannot even see.
        if ProjectRuntime.shared.selectedSession?.selectedTab?.isTerminal == false {
            _ = ProjectCloseCoordinator.closeSelected()
            return
        }
        // Splits are closed one at a time before the tab itself goes.
        if let controller, (controller.workspace?.paneCount ?? 1) > 1 {
            controller.requestClose()
            return
        }
        // Everything else defers to the one close policy, which is what knows
        // that closing a workspace's last tab retires the workspace and has to
        // ask first. Calling session.close directly here is what previously
        // made cmd+W silently reopen a fresh tab instead.
        if ProjectCloseCoordinator.closeSelected() == .handled {
            return
        }
        controller?.requestClose()
    }

    /// A browser tab in front owns find and zoom, and there may be no
    /// terminal at all in a workspace made of web tabs. Read through the
    /// runtime's revision so the items follow tab switches.
    private var isEnabled: Bool {
        _ = runtime.revision
        return controller != nil || BrowserOpener.selectedBrowser != nil
    }

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Split Pane") {
                if let controller {
                    controller.workspace?.split(controller, orientation: .vertical)
                }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Split Pane Horizontally") {
                if let controller {
                    controller.workspace?.split(controller, orientation: .horizontal)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!isEnabled)

            Button(controller?.workspace?.isZoomed == true ? "Unzoom Pane" : "Zoom Pane") {
                controller?.workspace?.toggleZoom()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!isEnabled || (controller?.workspace?.paneCount ?? 0) < 2)

            // cmd+W closes the split you are in when there is more than one,
            // otherwise the workspace tab. Closing a workspace's last tab
            // leaves a fresh one behind rather than an empty workspace.
            Button(closesTabRatherThanPane ? "Close Tab" : "Close Pane") {
                closeCurrent()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!isEnabled)

            Divider()

            // The tab strip carries a theme button, but it is hidden when a
            // workspace has a single tab, so the menu is the reliable route.
            Button("Theme…") {
                controller?.showThemePicker = true
            }
            .disabled(!isEnabled)

            Divider()

            Button("Export Buffer...") {
                controller?.exportBuffer()
            }
            .disabled(!isEnabled)
            Button("Export Selection...") {
                controller?.exportSelection()
            }
            .disabled(!isEnabled || controller?.selectionActive != true)

            Divider()

            Button("Clear Scrollback") {
                controller?.terminal?.clearScrollback()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!isEnabled)

            Divider()

            Button("Scroll to Previous Prompt") {
                controller?.scrollToPreviousPrompt()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!isEnabled)

            Button("Scroll to Next Prompt") {
                controller?.scrollToNextPrompt()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!isEnabled)

            Button("Soft Reset") {
                controller?.softReset()
            }
            .disabled(!isEnabled)
            Button("Hard Reset") {
                controller?.hardReset()
            }
            .disabled(!isEnabled)

            Divider()

            Toggle("Allow Mouse Reporting", isOn: binding(\.allowMouseReporting))
                .disabled(!isEnabled)
            Toggle("Use Option as Meta Key", isOn: binding(\.optionAsMetaKey))
                .disabled(!isEnabled)
            Toggle("Use Metal Renderer", isOn: binding(\.useMetalRenderer))
                .disabled(!isEnabled)
            Toggle("Use Per-Frame Metal Buffering", isOn: binding(\.usePerFrameMetalBuffering))
                .disabled(!isEnabled)
            Toggle("Log host output to ~/Downloads/Logs", isOn: binding(\.logHostOutput))
                .disabled(!isEnabled)
            Toggle("Secure Keyboard Entry", isOn: Bindable(secureKeyboardEntry).isEnabled)
            Toggle("Secure Keyboard Entry at Password Prompts",
                   isOn: Bindable(secureKeyboardEntry).protectsPasswordPrompts)

            Divider()

            Button("Bigger Font") {
                if let browser = BrowserOpener.selectedBrowser { browser.zoomIn(); return }
                controller?.biggerFont()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Smaller Font") {
                if let browser = BrowserOpener.selectedBrowser { browser.zoomOut(); return }
                controller?.smallerFont()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Default Font Size") {
                if let browser = BrowserOpener.selectedBrowser { browser.resetZoom(); return }
                controller?.defaultFontSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!isEnabled)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") {
                    performFindAction(.showFindInterface)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!isEnabled)

                Button("Find Next") {
                    performFindAction(.nextMatch)
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(!isEnabled)

                Button("Find Previous") {
                    performFindAction(.previousMatch)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!isEnabled)
            }

            Button("Paste Escaped") {
                pasteEscaped()
            }
            .keyboardShortcut("v", modifiers: [.command, .control])
            .disabled(!isEnabled)
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<TerminalSessionController, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller?[keyPath: keyPath] ?? false },
            set: { newValue in
                controller?[keyPath: keyPath] = newValue
            }
        )
    }

    private func performFindAction(_ action: NSTextFinder.Action) {
        // A browser tab in front owns find; the terminal behind it must not
        // open its find bar out of sight.
        if let browser = BrowserOpener.selectedBrowser {
            switch action {
            case .showFindInterface: browser.showFind()
            case .nextMatch: browser.findAgain(backwards: false)
            case .previousMatch: browser.findAgain(backwards: true)
            default: break
            }
            return
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        controller?.terminal?.performTextFinderAction(item)
    }

    private func pasteEscaped() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        controller?.terminal?.send(txt: escaped)
    }
}

struct TerminalPrintCommands: Commands {
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                commandState.controller?.printBuffer()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(commandState.controller == nil)
        }
    }
}

struct AppInfoCommands: Commands {
    /// Moo is built on Miguel de Icaza's work — SwiftTerm and Tecolot — and
    /// the About panel says so by name rather than leaving it to a license
    /// file nobody opens.
    private static let credits: NSAttributedString = {
        let text = """
        https://github.com/ventz/moo-mac-terminal

        Built on SwiftTerm and Tecolot by Miguel de Icaza.
        © 2026 Miguel de Icaza, MIT License

        https://github.com/migueldeicaza/SwiftTerm
        https://github.com/migueldeicaza/Tecolot

        Moo © 2026 Ventz Petkov, MIT License

        Includes Symbols Nerd Font (Nerd Fonts 3.4.0),
        © Nerd Fonts contributors, MIT License.
        """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: text,
            attributes: [
                .paragraphStyle: paragraph,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]
        )
    }()

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Moo") {
                NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
            }
        }
    }
}

private enum SettingsWindowID {
    static let value = "settings"
}

struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: SettingsWindowID.value)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@main
struct MooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        var registered: [String: Any] = [
            "useCommandDigitsForTabs": true,
            "startupMode": "default",
            "useMetalRenderer": true
        ]
        registered.merge(ProjectSidebarDefaults.registrationValues) { current, _ in current }
        registered.merge(LinkRoutingDefaults.registrationValues) { current, _ in current }
        registered.merge(ContentBlockingDefaults.registrationValues) { current, _ in current }
        UserDefaults.standard.register(defaults: registered)
        MarkdownPreviewOpener.install()
        BrowserOpener.install()
    }

    var body: some Scene {
        DocumentGroup(newDocument: TerminalDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
                .environmentObject(model.themeIndex)
                .environmentObject(model.projects)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AppInfoCommands()
            UpdateCommands()
            SettingsCommands()
            NewItemCommands()
            TabSelectionCommands()
            SplitCommands()
            ProfileCommands(profiles: model.profiles)
            ArrangementCommands(
                windowGroups: model.windowGroups,
                projects: model.projects
            )
            TerminalCommands()
            TerminalPrintCommands()
        }

        Window("Settings", id: SettingsWindowID.value) {
            SettingsView(issueCenter: model.issueCenter, recovery: model.recovery)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
                .environmentObject(model.themeIndex)
                .environmentObject(model.projects)
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
    }
}
