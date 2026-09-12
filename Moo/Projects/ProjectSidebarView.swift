//
//  ProjectSidebarView.swift
//  Moo
//
//  The projects list. Hosted in every terminal window's ContentView by way of
//  an HStack whose width animates to zero when hidden — deliberately not an
//  insertion/removal and not a NavigationSplitView, because SwiftUI makes no
//  promise about the lifetime of views it removes and this sidebar sits beside
//  a live terminal.
//
//  Selecting a row activates that project's window. Nothing is hidden,
//  unmounted or re-parented, so a running shell cannot be disturbed by
//  switching projects.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @ObservedObject var store: ProjectStore
    var runtime: ProjectRuntime
    /// The window this sidebar belongs to. Highlighting follows it, so two
    /// windows on different workspaces each show their own row selected.
    var scope: WindowScope
    var visibility: ProjectRowVisibility
    /// Supplied by the window so the sidebar matches the terminal's theme and
    /// transparency rather than painting its own material.
    var background: Color


    @State private var renameTarget: Project?
    @State private var errorMessage: String?
    @State private var modifiers = ModifierMonitor.shared
    @State private var draggingID: UUID?
    @State private var dropTargetID: UUID?
    @State private var dropEdge: VerticalEdge?
    @State private var rowHeights: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
        .background(background)
        .onAppear { runtime.refreshLocations(for: store.projects) }
        .onChange(of: store.projects) { _, projects in
            runtime.refreshLocations(for: projects)
        }
        .onChange(of: runtime.revision) {
            runtime.refreshLocations(for: store.projects)
        }
        .alert(
            "Could Not Change Projects",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private var list: some View {
        if store.projects.isEmpty {
            ScrollView { emptyState }
        } else {
            // Reading `revision` here is what subscribes the list to status and
            // branch updates. It used to be spent on `.id(runtime.revision)`,
            // which rebuilt the whole stack from scratch on every update —
            // including mid-drag, which is what made reordering feel janky.
            let _ = runtime.revision

            // A plain stack with explicit drag and drop rather than List's
            // onMove: the row needs a tap gesture to switch workspaces, and in
            // a List that gesture swallows the drag before a reorder can start.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        ProjectRowView(
                            project: project,
                            visibility: visibility.resolved(for: project),
                            report: runtime.status(for: project.id),
                            branch: runtime.branch(for: project.id),
                            directories: runtime.tabDirectories(for: project.id),
                            isSelected: project.id == scope.selectedProjectID,
                            shortcutNumber: shortcutNumber(for: index),
                            dropEdge: dropTargetID == project.id ? dropEdge : nil,
                            isBeingDragged: draggingID == project.id
                        )
                        .background {
                            // The drop delegate needs the row's height to tell
                            // an upper half from a lower one.
                            GeometryReader { proxy in
                                Color.clear.onAppear {
                                    rowHeights[project.id] = proxy.size.height
                                }
                                .onChange(of: proxy.size.height) { _, height in
                                    rowHeights[project.id] = height
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open(project) }
                        .onDrag {
                            draggingID = project.id
                            return NSItemProvider(object: project.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ProjectDropDelegate(
                                target: project,
                                rowHeight: rowHeights[project.id] ?? 44,
                                draggingID: $draggingID,
                                dropTargetID: $dropTargetID,
                                dropEdge: $dropEdge,
                                move: move
                            )
                        )
                        .contextMenu { contextMenu(for: project) }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .animation(.easeInOut(duration: 0.15), value: store.projects.map(\.id))
            }
        }
    }

    /// cmd+1...8 address the first eight projects; cmd+9 is always the last.
    /// Only revealed while Command is down — a permanent badge on every row is
    /// noise, since the shortcut is only actionable with the key held.
    private func shortcutNumber(for index: Int) -> Int? {
        guard modifiers.isCommandHeld, CommandDigitsTarget.current == .projects else {
            return nil
        }
        if index == store.projects.count - 1, store.projects.count > 8 { return 9 }
        return index < 8 ? index + 1 : nil
    }

    /// Reorders in place. The order is the cmd+digit order, so a drag also
    /// renumbers the shortcuts.
    ///
    /// `after` says which half of the target row the drop landed on, and must
    /// agree with where the insertion line was drawn — otherwise dropping on
    /// the top half of a row moves the project below it, which is what made
    /// the old behavior look wrong.
    private func move(_ dragged: UUID, target: UUID, after: Bool) {
        guard dragged != target else { return }
        var ordered = store.projects
        guard let from = ordered.firstIndex(where: { $0.id == dragged }) else { return }
        let project = ordered.remove(at: from)
        // Recomputed after the removal, so no index arithmetic is needed.
        guard let targetIndex = ordered.firstIndex(where: { $0.id == target }) else {
            return
        }
        ordered.insert(project, at: after ? targetIndex + 1 : targetIndex)
        do {
            try store.reorder(to: ordered.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Projects")
                .font(.headline)
            Text("Projects are labels. Name the terminal you are in, and it appears here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: addProject) {
                Label("Add Project", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help("Label the current terminal as a new project")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button("Switch to Project") { open(project) }
        Button("New Tab in Project") { openTab(in: project) }
        Divider()
        Button("Rename…") { rename(project) }
        Divider()
        Button("Delete Project", role: .destructive) { delete(project) }
    }

    // MARK: Actions

    /// Switches the terminal area to this workspace's tabs.
    private func open(_ project: Project) {
        runtime.select(projectID: project.id, in: scope)
        runtime.refreshLocations(for: [project])
    }

    private func openTab(in project: Project) {
        runtime.select(projectID: project.id, in: scope)
        runtime.session(for: project.id).addTab()
        runtime.invalidate()
    }

    private func rename(_ project: Project) {
        guard let name = ProjectPrompt.askForName(
            title: "Rename Project",
            message: "Projects are labels for organizing terminals.",
            initialValue: project.displayName(
                directory: runtime.currentDirectory(for: project.id)
            )
        ) else { return }
        var updated = project
        updated.name = name
        // An explicit name stops the row following the directory.
        updated.isAutoNamed = false
        do {
            try store.update(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addProject() {
        do {
            guard let name = ProjectPrompt.askForName(
                title: "New Project",
                message: "A project is a label for a set of terminal tabs."
            ) else { return }
            let project = try store.add(name: name)
            runtime.select(projectID: project.id, in: scope)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Delete the project \"\(project.name)\"?"
        alert.informativeText = """
            This removes the project from the sidebar. \
            Its terminals stay open and no files are changed.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(project.id)
            runtime.discardSession(for: project.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One row: name, optional status, and an optional "branch · ~/path" subtitle.
struct ProjectRowView: View {
    let project: Project
    let visibility: ProjectRowVisibility
    let report: ProjectStatusReport
    let branch: String?
    /// Where each of the workspace's tabs currently is, read live from the
    /// shells. Listing them all is what makes a workspace legible at a glance
    /// without expanding it.
    let directories: [String]
    let isSelected: Bool
    /// The cmd+digit that selects this row, when digits address projects.
    var shortcutNumber: Int?
    /// Which edge of this row a dragged project would land on, or nil when it
    /// is not the current drop target.
    var dropEdge: VerticalEdge?
    /// The row being dragged is dimmed so it reads as "in flight".
    var isBeingDragged = false

    var body: some View {
        HStack(spacing: 8) {
            if visibility.showsAccent, let accent = project.accentColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.swiftUIColor)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName(directory: directories.first))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if visibility.showsStatus {
                    statusLine
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)

            if let shortcutNumber {
                Text("\u{2318}\(shortcutNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        // The sidebar is intentionally narrow, so the row shows an
        // abbreviated form and hands over the whole of it on hover.
        .help(tooltip)
        .opacity(isBeingDragged ? 0.4 : 1)
        .overlay(alignment: dropEdge == .top ? .top : .bottom) {
            // Drawn on the edge the project will actually land on, so the line
            // is a promise the drop keeps.
            if dropEdge != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
    }

    /// Everything the row knows, unabbreviated and on separate lines: the
    /// name, what it is doing, its branch, and each tab's full path.
    private var tooltip: String {
        var lines = [project.displayName(directory: directories.first)]
        lines.append(statusText)
        if let branch, !branch.isEmpty {
            lines.append("Branch: \(branch)")
        }
        switch directories.count {
        case 0:
            break
        case 1:
            lines.append(directories[0])
        default:
            lines.append("Tabs:")
            lines.append(contentsOf: directories.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        // What the program said beats a generic "Waiting": it is the reason
        // to switch to this project.
        if report.status == .waiting, let message = report.message, !message.isEmpty {
            return message
        }
        if report.status == .attention, report.attentionCount > 1 {
            return "Activity in \(report.attentionCount) tabs"
        }
        return report.status.label
    }

    private var statusColor: Color {
        switch report.status {
        case .cold: return .secondary.opacity(0.4)
        case .idle: return .secondary
        case .running: return .blue
        case .attention: return .orange
        case .waiting: return .attentionWaiting
        }
    }

    /// "main  /bin | /tmp | /sbin" — the branch, when there is one, followed
    /// by every tab's directory. All of it comes from the live terminals, so
    /// it follows the user's `cd`. The active tab is not singled out here: the
    /// tab strip above already shows which one is selected.
    private var subtitle: String? {
        var parts: [String] = []
        if visibility.showsBranch, let branch, !branch.isEmpty {
            parts.append(branch)
        }
        if visibility.showsPath, !directories.isEmpty {
            parts.append(directories.map(\.abbreviatedPath).joined(separator: " | "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}


/// Reorders the sidebar as a project is dragged over a row.
///
/// Which half of the row the pointer is in decides whether the project lands
/// above or below it. Without that, there is no way to drop something at the
/// very end of the list, and the insertion line cannot honestly show where the
/// project is going.
private struct ProjectDropDelegate: DropDelegate {
    let target: Project
    let rowHeight: CGFloat
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropEdge: VerticalEdge?
    let move: (UUID, UUID, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil && draggingID != target.id
    }

    func dropEntered(info: DropInfo) {
        updateIndicator(info)
    }

    func dropExited(info: DropInfo) {
        guard dropTargetID == target.id else { return }
        dropTargetID = nil
        dropEdge = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
            dropEdge = nil
        }
        guard let dragged = draggingID, dragged != target.id else { return false }
        move(dragged, target.id, isBelowMidpoint(info))
        return true
    }

    private func updateIndicator(_ info: DropInfo) {
        guard let draggingID, draggingID != target.id else { return }
        let edge: VerticalEdge = isBelowMidpoint(info) ? .bottom : .top
        // Assigning unconditionally would republish on every pointer move and
        // make the drag stutter.
        if dropTargetID != target.id { dropTargetID = target.id }
        if dropEdge != edge { dropEdge = edge }
    }

    private func isBelowMidpoint(_ info: DropInfo) -> Bool {
        info.location.y > rowHeight / 2
    }
}
