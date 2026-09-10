//
//  WorkspaceTabBar.swift
//  Moo
//
//  The in-app tab strip for the selected workspace.
//
//  Tabs are Moo's own, not macOS window tabs. That is what allows each
//  workspace to own an independent set of them: native tabs are separate
//  windows sharing one strip, so they could never be grouped per workspace.
//
//  Visually this stands in for the native tab bar, so it follows the same
//  rules: full-width capsules that divide the available space evenly, drawn in
//  Liquid Glass, with a round add button trailing.
//

import AppKit
import SwiftUI

struct WorkspaceTabBar: View {
    var session: WorkspaceSession
    /// The terminal theme's colors. The strip sits directly above the terminal,
    /// so it takes the theme's background rather than a system material —
    /// otherwise a light chrome material floats over a dark terminal and reads
    /// as a foreign strip pasted onto the window.
    var background: Color
    var foreground: Color
    /// Opens the theme picker. It lives here rather than in a toolbar so the
    /// window keeps a plain, short titlebar like macOS Terminal's.
    var showThemePicker: (() -> Void)?

    @State private var hoveredTabID: WorkspaceTab.ID?

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                ForEach(session.tabs) { tab in
                    tabButton(tab)
                }
            }
            if let showThemePicker {
                circleButton("paintbrush", help: "Change the theme of this terminal") {
                    showThemePicker()
                }
            }
            newTabButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(background)
    }

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        let isSelected = tab.id == session.selectedTab?.id
        let isHovered = hoveredTabID == tab.id
        // Only offer to close when there is a choice to make; a lone tab is
        // replaced rather than removed, so a close control there is misleading.
        let showsClose = (isHovered || isSelected) && session.tabs.count > 1

        return ZStack {
            HStack(spacing: 4) {
                // Terminals are the default and carry no icon; a web tab is
                // marked so the strip shows at a glance which tabs are shells.
                if tab.kind != .terminal {
                    Image(systemName: tab.kind.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(foreground.opacity(isSelected ? 0.9 : 0.6))
                }
                Text(tab.displayTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(foreground.opacity(isSelected ? 1 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 24)

            if showsClose {
                HStack {
                    Button {
                        close(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(foreground.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .help("Close tab (⌘W)")
                    Spacer()
                }
                .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .background {
            // Every tab gets a container so an inactive tab still reads as a
            // tab; the active one is simply brighter. Deriving all three from
            // the theme's foreground keeps the contrast right in light and
            // dark themes without hard-coding either.
            Capsule().fill(
                foreground.opacity(isSelected ? 0.22 : (isHovered ? 0.14 : 0.07))
            )
        }
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
        .onTapGesture {
            session.select(tab)
            // Menu enablement follows the runtime's revision, so a click
            // must bump it like every other selection path does.
            ProjectRuntime.shared.invalidate()
        }
    }

    /// The x on a tab follows the same policy as cmd+W: a plain close while
    /// other tabs remain, and the workspace-retiring prompt for the last one.
    private func close(_ tab: WorkspaceTab) {
        if session.tabs.count > 1 {
            session.close(tab)
            ProjectRuntime.shared.invalidate()
        } else {
            _ = ProjectCloseCoordinator.closeSelected()
        }
    }

    private var newTabButton: some View {
        circleButton("plus", help: "New tab in this project (⌘T)") {
            session.addTab()
            ProjectRuntime.shared.invalidate()
        }
    }

    private func circleButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(foreground.opacity(0.12)))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

}
