//
//  WorkItemCardView.swift
//  workflow-manager
//
//  A board card, per design/ClaudeWM.fig › W02: number and priority, title,
//  tags, where Claude is with it, then the small facts — blocked, due,
//  subtasks, branch, owner.
//
//  `isCompact` draws the one-line form a completion column uses: done cards
//  are a record, not a to-do, and at full size twenty of them push everything
//  else off screen.
//

import SwiftUI
import SwiftData

struct WorkItemCardView: View {
    let item: WorkItem
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var accent: Color = .accentColor
    var isCompact: Bool = false

    var body: some View {
        Group {
            if isCompact { compact } else { full }
        }
        .opacity(isDimmed ? 0.35 : 1)
        .contentShape(.rect)
    }

    // MARK: - Compact

    private var compact: some View {
        HStack(spacing: 7) {
            Image(systemName: item.isDone ? "checkmark.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(item.isDone ? Theme.running : .secondary)
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let number = item.githubIssueNumber {
                Text("#\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(isSelected ? accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
    }

    // MARK: - Full

    private var full: some View {
        VStack(alignment: .leading, spacing: 7) {
            if item.githubIssueNumber != nil || item.priority != .normal {
                header
            }

            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .strikethrough(item.isDone, color: .secondary)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(accent.opacity(0.15), in: .rect(cornerRadius: 4))
                            .foregroundStyle(accent)
                    }
                }
            }

            agentSection

            if hasFooter {
                footer
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
    }

    private var borderColor: Color {
        if isSelected { return accent }
        if item.agentState == .queued { return Theme.agent.opacity(0.45) }
        return Theme.hairline
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let number = item.githubIssueNumber {
                // Same styling as `GitHubIssueCard`, which is what makes a card
                // and the issue it tracks read as the same thing.
                Text("#\(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(item.hasResolvableIssueLink ? .secondary : .tertiary)
                    .help(item.hasResolvableIssueLink
                          ? "Tracks GitHub issue #\(number)"
                          : "Linked to #\(number) in \(item.githubRepoSlug ?? "another repository"), which this project is no longer connected to")
            }
            Spacer(minLength: 0)
            priorityMark
        }
    }

    @ViewBuilder
    private var priorityMark: some View {
        switch item.priority {
        case .urgent:
            Text("Urgent")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Theme.danger.opacity(0.15), in: .rect(cornerRadius: 4))
        case .high:
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.warning)
                .help("High priority")
        case .low:
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .help("Low priority")
        case .normal:
            EmptyView()
        }
    }

    // MARK: - Claude

    @ViewBuilder
    private var agentSection: some View {
        switch item.agentState {
        case .working:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.agent).frame(width: 6, height: 6)
                    Text("Claude is working")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.agentText)
                }
                if let branch = item.workflowBranch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.agent.opacity(0.1), in: .rect(cornerRadius: 6))
        case .queued:
            Divider()
            Label("Queued for Claude", systemImage: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.agentText)
        case .inReview, .done:
            if let number = item.pullRequestNumber {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 11, weight: .semibold))
                    Text("PR #\(number)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("by Claude")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.running)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.running.opacity(0.1), in: .rect(cornerRadius: 6))
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: - Footer

    /// The branch moves into the Claude box while Claude is working on it.
    private var showsBranchInFooter: Bool {
        item.workflowBranch != nil && item.agentState != .working
    }

    private var hasFooter: Bool {
        item.dueDate != nil || !item.subtasks.isEmpty || !item.owner.isEmpty
            || item.isBlocked || showsBranchInFooter || imageCount > 0
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if item.isBlocked {
                chip(systemImage: "exclamationmark.octagon.fill", text: "Blocked", tint: Theme.warning)
                    .help("Blocked by \(item.openBlockers.count) unfinished item\(item.openBlockers.count == 1 ? "" : "s")")
            }
            if let dueDate = item.dueDate {
                chip(systemImage: "calendar", text: DateHelpers.chipLabel(for: dueDate), tint: dueTint)
            }
            if showsBranchInFooter, let branch = item.workflowBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            if !item.subtasks.isEmpty {
                chip(
                    systemImage: "checklist",
                    text: "\(item.completedSubtaskCount)/\(item.subtaskCount)",
                    tint: .secondary
                )
            }
            if imageCount > 0 {
                chip(systemImage: "photo", text: "\(imageCount)", tint: .secondary)
                    .help("\(imageCount) image\(imageCount == 1 ? "" : "s") in the notes")
            }
            Spacer(minLength: 0)
            if !item.owner.isEmpty {
                Text(item.owner.prefix(2).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(accent.gradient, in: .circle)
                    .help(item.owner)
            }
        }
    }

    /// Images the notes show — not stored ones whose reference was deleted.
    private var imageCount: Int {
        item.attachments.isEmpty ? 0 : AttachmentReferences.ids(in: item.details).count
    }

    private var dueTint: Color {
        if item.isOverdue { return Theme.danger }
        if item.isDueSoon { return Theme.warning }
        return .secondary
    }

    private func chip(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text).monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 10) {
        if let project = SampleData.firstProject {
            ForEach(project.allItems.prefix(6), id: \.uuid) { item in
                WorkItemCardView(item: item, accent: project.accent.color, isCompact: item.isDone)
            }
        }
    }
    .padding()
    .frame(width: 280)
    .modelContainer(SampleData.container)
}
#endif
