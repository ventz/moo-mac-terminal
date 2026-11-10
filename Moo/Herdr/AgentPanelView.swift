//
//  AgentPanelView.swift
//  Moo
//
//  The sidebar's agent panel: every agent Moo reads from herdr, from a herdr
//  0.9 client in a Moo tab or from herdr-core (the Herdr app's daemon),
//  grouped by workspace or space, below the projects list.
//
//  A click opens the agent: a herdr 0.9 agent is shown where it runs, and a
//  herdr-core agent opens in a new tab with `hc attach`. Its colors come
//  from the theme's `agentPanel` colors when the window takes the theme's
//  colors, and otherwise follow the system.
//

import SwiftUI

/// The agent panel's colors, resolved from a theme.
struct AgentPanelStyle: Equatable {
    /// nil: the sidebar's own background shows through.
    var background: Color?
    var text: Color
    var secondaryText: Color
    var working: Color
    var blocked: Color
    var finished: Color
    var idle: Color
    var error: Color

    /// The look before themes could set it, and with an unthemed window.
    static let standard = AgentPanelStyle(
        background: nil,
        text: .primary,
        secondaryText: .secondary,
        working: .blue,
        blocked: .attentionWaiting,
        finished: .orange,
        idle: .secondary,
        error: .red
    )

    /// The theme's colors over the defaults. Only a themed window takes
    /// them: an unthemed one follows the system, and a theme's panel color
    /// would clash with it.
    init(theme: TerminalTheme?, themed: Bool) {
        self = .standard
        guard themed, let colors = theme?.agentPanel else { return }
        background = colors.background?.swiftUIColor ?? background
        text = colors.text?.swiftUIColor ?? text
        secondaryText = colors.secondaryText?.swiftUIColor ?? secondaryText
        working = colors.working?.swiftUIColor ?? working
        blocked = colors.blocked?.swiftUIColor ?? blocked
        finished = colors.finished?.swiftUIColor ?? finished
        idle = colors.idle?.swiftUIColor ?? idle
        error = colors.error?.swiftUIColor ?? error
    }

    private init(background: Color?, text: Color, secondaryText: Color, working: Color,
                 blocked: Color, finished: Color, idle: Color, error: Color) {
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.working = working
        self.blocked = blocked
        self.finished = finished
        self.idle = idle
        self.error = error
    }

    func color(for status: HerdrAgentStatus) -> Color {
        switch status {
        case .working: return working
        case .blocked: return blocked
        case .done: return finished
        case .error: return error
        case .idle, .unknown: return idle
        }
    }
}

struct AgentPanelView: View {
    let rows: [HerdrPanelRow]
    let style: AgentPanelStyle
    /// The list's height, which the divider above the panel sets.
    var listHeight: CGFloat = CGFloat(HerdrDefaults.defaultAgentPanelHeight)
    /// Made-up names and ASCII critters (Settings → herdr).
    var showsCritters = false
    /// Opens a row; true to watch a herdr-core agent without typing into it.
    let open: (HerdrPanelRow, Bool) -> Void

    @AppStorage(HerdrDefaults.agentPanelCollapsed) private var isCollapsed = false

    /// The shortest list the divider can be dragged to, and how much of the
    /// sidebar the projects above always keep.
    static let minimumListHeight: CGFloat = 60
    static let projectsReserve: CGFloat = 160

    /// The stored height, kept between the minimum and what the sidebar
    /// can give without squeezing out the projects. A sidebar not yet
    /// measured (height 0) does not clamp.
    static func clampedListHeight(_ stored: CGFloat, sidebarHeight: CGFloat) -> CGFloat {
        var height = max(stored, minimumListHeight)
        if sidebarHeight > 0 {
            height = min(height, max(minimumListHeight, sidebarHeight - projectsReserve))
        }
        return height
    }

    private struct Group: Identifiable {
        let name: String
        let rows: [HerdrPanelRow]
        var id: String { name }
    }

    /// Rows arrive sorted by group, so consecutive runs are the groups.
    private var groups: [Group] {
        var groups: [Group] = []
        for row in rows {
            if let last = groups.last, last.name == row.group {
                groups[groups.count - 1] = Group(name: last.name, rows: last.rows + CollectionOfOne(row))
            } else {
                groups.append(Group(name: row.group, rows: [row]))
            }
        }
        return groups
    }

    private var needsYouCount: Int {
        rows.filter { $0.status == .blocked && !$0.isDetached }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                if rows.isEmpty {
                    Text("No agents running")
                        .font(.system(size: 10))
                        .foregroundStyle(style.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background ?? .clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text("AGENTS")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 4)
                if needsYouCount > 0 {
                    Circle()
                        .fill(style.blocked)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("\(needsYouCount) need you")
                }
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            .foregroundStyle(style.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show agents" : "Hide agents")
    }

    private var list: some View {
        let identities = showsCritters ? AgentCritters.assign(rows.map(\.id)) : [:]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(groups) { group in
                    Text(group.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    ForEach(group.rows) { row in
                        if let identity = identities[row.id] {
                            critterRow(row, identity: identity)
                        } else {
                            rowView(row)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(height: listHeight)
    }

    /// A row with a name and a critter: the critter on the left, its face
    /// in the status color; the made-up name, then the agent, then what
    /// the session is about.
    private func critterRow(_ row: HerdrPanelRow, identity: AgentCritters.Identity) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(AgentCritters.art(species: identity.species, status: row.status))
                .font(.system(size: 8, design: .monospaced))
                .lineSpacing(-1)
                .foregroundStyle(row.isDetached ? style.idle.opacity(0.4) : style.color(for: row.status))
                .fixedSize()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(identity.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                }
                Text(row.agent)
                    .font(.system(size: 10))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary = row.summary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .opacity(row.isDetached ? 0.6 : 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .rowInteractions(row, open: open)
    }

    private func rowView(_ row: HerdrPanelRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.isDetached ? style.idle.opacity(0.4) : style.color(for: row.status))
                    .frame(width: 6, height: 6)
                Text(row.agent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(row.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
            if let summary = row.summary {
                // Under the name, past the dot.
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 12)
            }
        }
        .opacity(row.isDetached ? 0.6 : 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .rowInteractions(row, open: open)
    }
}

private extension View {
    /// Click to open, the row's menu, its tooltip, and one accessibility
    /// element: the same for plain and critter rows.
    func rowInteractions(_ row: HerdrPanelRow, open: @escaping (HerdrPanelRow, Bool) -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { open(row, false) }
            .help(row.detail)
            .contextMenu {
                switch row.source {
                case .session:
                    Button("Show Agent") { open(row, false) }
                case .core:
                    Button("Open in New Tab") { open(row, false) }
                    Button("Watch in New Tab") { open(row, true) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}
