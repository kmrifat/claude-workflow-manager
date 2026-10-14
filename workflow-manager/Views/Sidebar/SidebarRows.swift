//
//  SidebarRows.swift
//  workflow-manager
//
//  The building blocks the sidebar is assembled from. Sizes follow
//  design/ClaudeWM.fig › SB: rows 28 pt (views 26), headers 24, 18 pt indent per
//  level, 16 pt icons, 18 pt badges, 12 pt chevrons.
//

import SwiftUI

/// A project's icon on a filled square of its accent colour.
struct ProjectBadge: View {
    let project: Project
    var size: CGFloat = Theme.Sidebar.badge

    var body: some View {
        Image(systemName: project.symbolName)
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(project.accent.color.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}

/// Disclosure state of a row's leading chevron.
enum Disclosure {
    /// No chevron, and no space for one.
    case none
    /// No chevron, but its space is kept so names line up with siblings that
    /// have one.
    case placeholder
    case open
    case closed
}

/// One row of the tree. Selection is drawn here, by hand — the cost of
/// building the sidebar on a `ScrollView` so folds can animate (see
/// `ProjectSidebar`).
struct SidebarRow<Icon: View, Accessory: View>: View {
    var depth: Int = 0
    var height: CGFloat = Theme.Sidebar.rowHeight
    var disclosure: Disclosure = .none
    var isSelected: Bool = false
    /// The open project: bold, on a faint fill, so it stays findable while one
    /// of its views holds the real selection.
    var isEmphasized: Bool = false
    var onDisclosure: (() -> Void)?
    let title: String
    var subtitle: AnyView?
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 6) {
            chevron
            icon()
                .frame(minWidth: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: height < Theme.Sidebar.rowHeight ? 12 : 13,
                                  weight: isEmphasized ? .semibold : (isSelected ? .medium : .regular)))
                    .lineLimit(1)
                if let subtitle { subtitle }
            }
            Spacer(minLength: 4)
            accessory()
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(.leading, 8 + CGFloat(depth) * Theme.Sidebar.indent)
        .padding(.trailing, 8)
        .padding(.vertical, subtitle == nil ? 0 : 5)
        .frame(minHeight: height)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(background, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isEmphasized { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return AnyShapeStyle(Color.clear)
    }

    @ViewBuilder
    private var chevron: some View {
        switch disclosure {
        case .none:
            EmptyView()
        case .placeholder:
            Color.clear.frame(width: 12, height: 12)
        case .open, .closed:
            Button {
                withAnimation(.smooth(duration: 0.25)) { onDisclosure?() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(disclosure == .open ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
    }
}

extension SidebarRow where Accessory == EmptyView {
    init(
        depth: Int = 0,
        height: CGFloat = Theme.Sidebar.rowHeight,
        disclosure: Disclosure = .none,
        isSelected: Bool = false,
        title: String,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.init(depth: depth, height: height, disclosure: disclosure, isSelected: isSelected,
                  title: title, icon: icon, accessory: { EmptyView() })
    }
}

/// A section header: Pinned, a workspace, Archived. Small, bold, secondary,
/// with its count and a fold chevron on the trailing edge — the convention
/// Finder and Mail use, so a closed section always shows it can open.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    var symbol: String?
    var count: Int?
    let isOpen: Bool
    var onToggle: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { onToggle() }
        } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(isOpen && !isHovered ? 0 : 1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: Theme.Sidebar.headerHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.top, 8)
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, count: Int? = nil, isOpen: Bool, onToggle: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, count: count, isOpen: isOpen, onToggle: onToggle,
                  accessory: { EmptyView() })
    }
}

/// A coloured dot, optionally with a number — the sidebar's whole vocabulary
/// for live state: purple is Claude, green is running, red is late.
struct StatusDot: View {
    let color: Color
    var count: Int?
    var label: String?
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: size, height: size)
            if let count {
                Text(label.map { "\(count) \($0)" } ?? "\(count)")
                    .font(.system(size: 10))
                    .monospacedDigit()
            }
        }
    }
}

/// What a closed folder is hiding: agents at work, running commands, late
/// cards. Shown only when non-zero, so a quiet folder stays one line.
@MainActor
struct FolderRollup {
    var agents = 0
    var running = 0
    var late = 0

    var isEmpty: Bool { agents + running + late == 0 }

    init(projects: [Project], terminals: TerminalStateStore?) {
        for project in projects where project.status != .archived {
            agents += project.allItems.count { $0.agentState == .working }
            if terminals?.model(for: project.uuid).hasRunning == true { running += 1 }
            late += project.overdueCount
        }
    }

    @ViewBuilder
    var view: some View {
        HStack(spacing: 8) {
            if agents > 0 { StatusDot(color: Theme.agent, count: agents, label: agents == 1 ? "agent" : "agents", size: 5) }
            if running > 0 { StatusDot(color: Theme.running, count: running, label: "running", size: 5) }
            if late > 0 { StatusDot(color: Theme.danger, count: late, label: "late", size: 5) }
        }
        .foregroundStyle(.secondary)
    }
}
