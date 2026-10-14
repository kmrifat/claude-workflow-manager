//
//  CardQueueView.swift
//  workflow-manager
//
//  A sidebar smart list — Agents Working, Needs Review, Overdue — as one table
//  of cards from every project, grouped by project. Clicking a card opens it on
//  its own board.
//

import SwiftUI
import SwiftData

struct CardQueueView: View {
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    let queue: CardQueue
    var open: (WorkItem) -> Void

    var body: some View {
        let groups = queue.items(in: projects)
        let total = groups.reduce(0) { $0 + $1.items.count }
        Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    queue.title,
                    systemImage: queue.symbol,
                    description: Text(queue.emptyMessage)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                        ForEach(groups, id: \.project.uuid) { group in
                            section(group.project, group.items)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(.background)
        .navigationTitle(queue.title)
        .navigationSubtitle(
            "\(total) card\(total == 1 ? "" : "s") in \(groups.count) project\(groups.count == 1 ? "" : "s")"
        )
    }

    private func section(_ project: Project, _ items: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProjectBadge(project: project, size: 20)
                Text(project.name).font(.system(size: 13, weight: .bold))
                if let path = project.folder?.path.map(\.displayName).joined(separator: " › ") {
                    Text(path).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.uuid) { index, item in
                    CardRow(item: item, showsProject: false, accessory: accessory)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        .onTapGesture { open(item) }
                }
            }
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
        }
    }

    private var accessory: CardRow.Accessory {
        switch queue {
        case .agents:  .agent
        case .review:  .pullRequest
        case .overdue: .due
        }
    }
}

/// One card as a table row: number, title, where it is, and one detail on the
/// trailing edge chosen by the list it is in.
struct CardRow: View {
    let item: WorkItem
    var showsProject: Bool
    var accessory: Accessory

    enum Accessory {
        case agent, pullRequest, due
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsProject, let project = item.project {
                ProjectBadge(project: project, size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let number = item.githubIssueNumber {
                        Text("#\(number)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .contentShape(.rect)
    }

    private var location: String {
        var parts: [String] = []
        if showsProject, let project = item.project { parts.append(project.name) }
        if let column = item.column { parts.append(column.name) }
        if let branch = item.workflowBranch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch accessory {
        case .agent:
            switch item.agentState {
            case .working:
                Label("Working", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.agentText)
            case .queued:
                Text("Queued")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        case .pullRequest:
            if let number = item.pullRequestNumber {
                Label("PR #\(number)", systemImage: "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.running)
            }
        case .due:
            if let due = item.dueDate {
                Text(DateHelpers.chipLabel(for: due))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.isOverdue ? Theme.danger : (item.isDueSoon ? Theme.warning : .secondary))
            }
        }
    }
}
