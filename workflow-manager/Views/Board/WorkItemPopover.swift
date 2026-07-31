//
//  WorkItemPopover.swift
//  workflow-manager
//
//  What a click on a board card shows: the card's detail, anchored to the card
//  itself rather than pushed into a side panel or a modal.
//
//  Deliberately *not* the whole editor. A popover is a glance and a few quick
//  actions — retitle, repriority, send to Claude, open the issue. Everything
//  long-form (subtasks, tags, both dates, notes editing) stays in
//  `WorkItemEditorSheet`, which "Edit Details" opens. Reproducing the full form
//  here would mean two editors to keep in step, and a popover tall enough to
//  cover the board it is anchored to.
//

import SwiftUI
import SwiftData

struct WorkItemPopover: View {
    @Bindable var item: WorkItem
    var accent: Color = .accentColor
    /// Opens the full inspector for this card.
    var onEditDetails: () -> Void
    var onDelete: () -> Void
    /// Both of these are presented by the *board*, not here.
    ///
    /// A sheet opened from inside a popover on macOS races the popover's own
    /// dismissal — the popover closes as focus moves, taking the half-presented
    /// sheet with it. So the popover closes first and asks its host to present.
    var onCreateIssue: () -> Void
    var onLinkIssue: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkflowSyncModel.self) private var sync: WorkflowSyncModel?

    private var project: Project? { item.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !item.details.isEmpty {
                        // Rendered like a GitHub issue body rather than dumped as
                        // raw text — same renderer, so the two read alike.
                        IssueMarkdownView(markdown: item.details, accent: accent)
                    }

                    attributes

                    if !item.tags.isEmpty { tags }

                    if let project, project.hasRepository {
                        Button {
                            dismiss()
                            NotificationCenter.default.post(
                                name: .startClaudeForItem,
                                object: nil,
                                userInfo: ["itemID": item.uuid.uuidString]
                            )
                        } label: {
                            Label("Start Claude Session", systemImage: "sparkles")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.link)
                    }

                    if let project, project.hasRepository {
                        Divider()
                        githubSection(for: project)
                    }

                    if let project, project.isSyncing, let sync {
                        Divider()
                        claudeSection(for: project, sync: sync)
                    }
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if let number = item.githubIssueNumber {
                Text("#\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.hasResolvableIssueLink ? .secondary : .tertiary)
            }

            TextField("Title", text: $item.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1...3)

            if let column = item.column {
                Text(column.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                    .fixedSize()
            }
        }
        .padding(14)
    }

    private var attributes: some View {
        HStack(spacing: 10) {
            Picker("", selection: priorityBinding) {
                ForEach(Priority.allCases) { priority in
                    Label(priority.title, systemImage: priority.symbol).tag(priority)
                }
            }
            .labelsHidden()
            .fixedSize()

            if let dueDate = item.dueDate {
                Label(DateHelpers.chipLabel(for: dueDate), systemImage: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(dueTint)
            }

            if !item.subtasks.isEmpty {
                Label(
                    "\(item.completedSubtaskCount)/\(item.subtasks.count)",
                    systemImage: "checklist"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if item.isBlocked {
                Label("Blocked", systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .help("Blocked by \(item.openBlockers.count) unfinished item\(item.openBlockers.count == 1 ? "" : "s")")
            }

            Spacer(minLength: 0)
        }
    }

    private var tags: some View {
        HStack(spacing: 4) {
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.14), in: .capsule)
                    .foregroundStyle(accent)
            }
            if item.tags.count > 4 {
                Text("+\(item.tags.count - 4)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func githubSection(for project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GITHUB")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            if item.githubIssueNumber != nil {
                if let url = item.githubIssueURL {
                    Link(destination: url) {
                        Label("Open Issue on GitHub", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 11))
                    }
                } else {
                    Text("Linked to \(item.githubRepoSlug ?? "another repository"), which this project is no longer connected to.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button("Unlink") { IssueLinking.unlink(item) }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            } else {
                // The only action in the app that writes to GitHub. Named
                // plainly, and it still asks before filing anything.
                Button("Create GitHub Issue…") {
                    dismiss()
                    onCreateIssue()
                }
                .font(.system(size: 11))
                .buttonStyle(.link)

                Button("Link to Existing Issue…") {
                    dismiss()
                    onLinkIssue()
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func claudeSection(for project: Project, sync: WorkflowSyncModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            if item.workflowRequested {
                Label("Waiting for a session to pick this up", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel Request") {
                    item.workflowRequested = false
                    Task { await sync.writeNow(for: project, context: context) }
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            } else {
                Button("Send to Claude") {
                    item.workflowRequested = true
                    Task { await sync.writeNow(for: project, context: context) }
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            }

            if let branch = item.workflowBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let prUrl = item.workflowPRURL, let url = URL(string: prUrl) {
                Link(destination: url) {
                    Label("Open Pull Request", systemImage: "arrow.up.forward.square")
                        .font(.system(size: 11))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Edit Details") {
                dismiss()
                onEditDetails()
            }
            .font(.system(size: 11))

            Spacer()

            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this item")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers

    private var priorityBinding: Binding<Priority> {
        Binding(get: { item.priority }, set: { item.priority = $0 })
    }

    private var dueTint: Color {
        if item.isOverdue { return .red }
        if item.isDueSoon { return .orange }
        return .secondary
    }
}
