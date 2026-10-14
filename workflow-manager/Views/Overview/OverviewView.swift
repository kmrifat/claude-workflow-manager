//
//  OverviewView.swift
//  workflow-manager
//
//  Where the app opens: every project at once. Replaces "No Project
//  Selected", which with thirty projects was the least useful screen in the
//  app. Design: design/ClaudeWM.fig › W01.
//
//  Everything here is derived from the boards — there is no activity log to
//  read, so there is no activity feed. What is shown is what the boards say
//  right now.
//

import SwiftUI
import SwiftData

struct OverviewView: View {
    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Query private var folders: [ProjectFolder]
    @Environment(TerminalStateStore.self) private var terminalStore: TerminalStateStore?

    var open: (WorkItem) -> Void
    var openProject: (Project) -> Void

    private var live: [Project] {
        projects.filter { $0.status != .archived }
    }

    private var workspaceCount: Int {
        folders.count { $0.parent == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                stats
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 22) {
                        agentsPanel
                        projectsPanel
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 22) {
                        reviewPanel
                        duePanel
                    }
                    .frame(width: 340)
                }
            }
            .padding(24)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("Overview")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        var parts = ["\(live.count) project\(live.count == 1 ? "" : "s")"]
        if workspaceCount > 0 { parts.append("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")") }
        parts.append(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
        return parts.joined(separator: " · ")
    }

    // MARK: - Stats

    private var stats: some View {
        let inProgress = live.reduce(0) { $0 + $1.inProgressCount }
        let active = live.count { $0.status == .active }
        return HStack(spacing: 12) {
            StatTile(title: "Active projects", value: active, caption: "of \(live.count)")
            StatTile(title: "In progress", value: inProgress, caption: inProgress == 1 ? "card" : "cards")
            StatTile(title: "Agents working", value: CardQueue.agents.count(in: projects),
                     caption: "via Claude", tint: Theme.agentText)
            StatTile(title: "Needs review", value: CardQueue.review.count(in: projects),
                     caption: "cards", tint: Theme.warning)
            StatTile(title: "Overdue", value: CardQueue.overdue.count(in: projects),
                     caption: "cards", tint: Theme.danger)
        }
    }

    // MARK: - Panels

    private var agentsPanel: some View {
        let working = CardQueue.agents.items(in: projects).flatMap(\.items)
        let queued = live.flatMap(\.allItems).filter { $0.agentState == .queued }
        return Panel(title: "Agents right now", trailing: queued.isEmpty ? nil : "\(queued.count) queued") {
            if working.isEmpty && queued.isEmpty {
                PanelEmpty(text: "No card is with Claude. Send one from a card’s menu on a synced board.")
            } else {
                ForEach(working, id: \.uuid) { item in
                    CardRow(item: item, showsProject: true, accessory: .agent).onTapGesture { open(item) }
                    Divider()
                }
                ForEach(queued.prefix(5), id: \.uuid) { item in
                    CardRow(item: item, showsProject: true, accessory: .agent).onTapGesture { open(item) }
                    Divider()
                }
            }
        }
    }

    /// Busiest first: cards in progress, then cards still open.
    private var projectsPanel: some View {
        let ranked = live
            .filter { $0.totalCount > 0 }
            .sorted { ($0.inProgressCount, $0.openCount) > ($1.inProgressCount, $1.openCount) }
            .prefix(8)
        return Panel(title: "Most active projects", trailing: "By cards in progress") {
            HStack(spacing: 12) {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Workspace").frame(width: 120, alignment: .leading)
                Text("Progress").frame(width: 150, alignment: .leading)
                Text("Active").frame(width: 56, alignment: .leading)
                Text("Due").frame(width: 70, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color.primary.opacity(0.04))
            if ranked.isEmpty {
                PanelEmpty(text: "No project has cards yet.")
            }
            ForEach(Array(ranked.enumerated()), id: \.element.uuid) { index, project in
                projectRow(project)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    .contentShape(.rect)
                    .onTapGesture { openProject(project) }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let agents = project.allItems.count { $0.agentState == .working }
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                ProjectBadge(project: project)
                Text(project.name).font(.system(size: 13)).lineLimit(1)
                if terminalStore?.model(for: project.uuid).hasRunning == true {
                    Circle().fill(Theme.running).frame(width: 6, height: 6).help("Commands running")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(project.folder?.workspace.displayName ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            HStack(spacing: 8) {
                ProgressCapsule(
                    progress: project.progress,
                    tint: project.progress >= 0.8 ? Theme.running : .accentColor
                )
                .frame(width: 90)
                Text("\(project.completedCount)/\(project.totalCount)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            HStack(spacing: 4) {
                if agents > 0 { Circle().fill(Theme.agent).frame(width: 6, height: 6) }
                Text("\(project.inProgressCount)").monospacedDigit()
            }
            .font(.system(size: 12))
            .frame(width: 56, alignment: .leading)
            dueLabel(project)
                .frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    @ViewBuilder
    private func dueLabel(_ project: Project) -> some View {
        if let days = project.daysRemaining, let end = project.targetEndDate {
            if days < 0 {
                Text("\(-days)d late").foregroundStyle(Theme.danger)
            } else {
                Text(end.formatted(.dateTime.month(.abbreviated).day()))
                    .foregroundStyle(project.isBehindSchedule ? Theme.warning : .primary)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private var reviewPanel: some View {
        let items = CardQueue.review.items(in: projects).flatMap(\.items)
        return Panel(title: "Needs review", trailing: items.isEmpty ? nil : "\(items.count)") {
            if items.isEmpty {
                PanelEmpty(text: "Nothing is waiting in a review column.")
            }
            ForEach(items.prefix(6), id: \.uuid) { item in
                CardRow(item: item, showsProject: true, accessory: .pullRequest).onTapGesture { open(item) }
                Divider()
            }
        }
    }

    private var duePanel: some View {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let items = live.flatMap(\.allItems)
            .filter { !$0.isDone && ($0.dueDate.map { $0 <= horizon } ?? false) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        return Panel(title: "Due this week", trailing: items.isEmpty ? nil : "\(items.count)") {
            if items.isEmpty {
                PanelEmpty(text: "Nothing is due in the next seven days.")
            }
            ForEach(items.prefix(8), id: \.uuid) { item in
                CardRow(item: item, showsProject: true, accessory: .due).onTapGesture { open(item) }
                Divider()
            }
        }
    }
}

// MARK: - Pieces

struct StatTile: View {
    let title: String
    let value: Int
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(value)")
                    .font(.system(size: 24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
    }
}

/// A titled group box, the Overview's one container.
struct Panel<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
        }
    }
}

struct PanelEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}
