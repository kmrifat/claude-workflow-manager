//
//  WorkItemCardView.swift
//  workflow-manager
//

import SwiftUI
import SwiftData

struct WorkItemCardView: View {
    let item: WorkItem
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if let number = item.githubIssueNumber {
                    // Same styling as `GitHubIssueCard`, which is what makes a
                    // card and the issue it tracks read as the same thing.
                    Text("#\(number)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.hasResolvableIssueLink ? .secondary : .tertiary)
                        .help(item.hasResolvableIssueLink
                              ? "Tracks GitHub issue #\(number)"
                              : "Linked to #\(number) in \(item.githubRepoSlug ?? "another repository"), which this project is no longer connected to")
                }

                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)

                Spacer(minLength: 0)

                if item.priority != .normal {
                    Image(systemName: item.priority.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.priority.color)
                        .help("\(item.priority.title) priority")
                }
            }

            if !item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.14), in: .capsule)
                            .foregroundStyle(accent)
                    }
                }
            }

            if hasFooter {
                HStack(spacing: 8) {
                    if item.isBlocked {
                        chip(
                            systemImage: "exclamationmark.octagon.fill",
                            text: "Blocked",
                            tint: .orange
                        )
                        .help("Blocked by \(item.openBlockers.count) unfinished item\(item.openBlockers.count == 1 ? "" : "s")")
                    }
                    if let dueDate = item.dueDate {
                        chip(
                            systemImage: "calendar",
                            text: DateHelpers.chipLabel(for: dueDate),
                            tint: dueTint
                        )
                    }
                    if !item.subtasks.isEmpty {
                        chip(
                            systemImage: "checklist",
                            text: "\(item.completedSubtaskCount)/\(item.subtasks.count)",
                            tint: .secondary
                        )
                    }
                    Spacer(minLength: 0)
                    if !item.owner.isEmpty {
                        Text(item.owner.prefix(2).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(.quaternary, in: .circle)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? accent : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .opacity(isDimmed ? 0.35 : 1)
        .contentShape(.rect)
    }

    private var hasFooter: Bool {
        item.dueDate != nil || !item.subtasks.isEmpty || !item.owner.isEmpty || item.isBlocked
    }

    private var dueTint: Color {
        if item.isOverdue { return .red }
        if item.isDueSoon { return .orange }
        return .secondary
    }

    private func chip(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 10) {
        if let project = SampleData.firstProject,
           let column = project.orderedColumns.first(where: { !$0.items.isEmpty }) {
            ForEach(column.orderedItems, id: \.uuid) { item in
                WorkItemCardView(item: item, accent: project.accent.color)
            }
        }
    }
    .padding()
    .frame(width: 300)
    .modelContainer(SampleData.container)
}
#endif
