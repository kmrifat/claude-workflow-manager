//
//  CardPopover.swift
//  workflow-manager
//
//  A card at a glance, anchored to it on the board — design/ClaudeWM.fig ›
//  C01. Enough to answer "where is this, and what is Claude doing with it",
//  and to tick a subtask or move it on; anything longer is one click away in
//  its own window (`CardWindow`), behind "Open in Window" or ⌘O.
//
//  Nothing here presents a sheet. A sheet presented from inside a popover is
//  torn down with it as focus moves, so issue linking, blockers and the like
//  live in the window.
//

import SwiftUI
import SwiftData

struct CardPopover: View {
    @Bindable var item: WorkItem
    var onOpenWindow: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(WorkflowSyncModel.self) private var sync: WorkflowSyncModel?
    @Environment(MCPServer.self) private var mcp: MCPServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 8)
                    Text(item.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(item.title.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    if !preview.isEmpty {
                        IssueMarkdownView(markdown: preview, accent: item.project?.accent.color ?? .accentColor)
                            .font(.system(size: 12.5))
                            .padding(.bottom, 2)
                        if preview.count < item.details.count {
                            Button("Show all notes", action: onOpenWindow)
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .padding(.bottom, 8)
                        }
                    }
                    if item.agentState != .none {
                        CardClaudeCallout(item: item, compact: true)
                            .padding(.vertical, 6)
                    }
                    properties
                        .padding(.top, 6)
                    if !item.orderedSubtasks.isEmpty {
                        Divider().padding(.vertical, 10)
                        subtasks
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: 392)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            CardColumnMenu(item: item)
            if let number = item.githubIssueNumber {
                Text("#\(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.priority >= .high {
                Text(item.priority.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(item.priority.chipColor)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(item.priority.chipColor.opacity(0.15), in: .rect(cornerRadius: 4))
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Open in Window", action: onOpenWindow)
            Divider()
            if item.agentState == .none, !item.isDone, CardActions.claudeIsReachable(item, mcp: mcp) {
                Button("Send to Claude") {
                    CardActions.setRequested(true, on: item, sync: sync, context: context)
                }
                .disabled(item.isBlocked)
            } else if item.workflowRequested, item.agentState == .queued {
                Button("Cancel Claude Request") {
                    CardActions.setRequested(false, on: item, sync: sync, context: context)
                }
            }
            Menu("Priority") {
                ForEach(Priority.allCases.reversed()) { priority in
                    Button(priority == item.priority ? "✓ \(priority.title)" : priority.title) {
                        item.priority = priority
                    }
                }
            }
            if let url = item.githubIssueURL {
                Link("Open Issue on GitHub", destination: url)
            }
            Divider()
            Button("Duplicate") { withAnimation(.snappy) { BoardMutations.duplicate(item, in: context) } }
            Button("Delete", role: .destructive) { withAnimation(.snappy) { context.delete(item) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Card actions")
    }

    // MARK: - Notes

    /// The first few blocks of the notes — a glance, not the document.
    private var preview: String {
        let lines = item.details.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var characters = 0
        for line in lines {
            if kept.count >= 6 || characters > 360 { break }
            kept.append(line)
            characters += line.count
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Properties

    private var properties: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let due = item.dueDate {
                row("Due") {
                    Text(dueText(due))
                        .foregroundStyle(item.isOverdue ? Theme.danger : (item.isDueSoon ? Theme.warning : .primary))
                }
            }
            if !item.owner.isEmpty {
                row("Owner") { Text(item.owner) }
            }
            if let branch = item.workflowBranch {
                row("Branch") {
                    Text(branch)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if item.isBlocked {
                row("Blocked by") {
                    Text(item.openBlockers.map(\.displayTitle).formatted(.list(type: .and)))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
            }
            if !item.tags.isEmpty {
                row("Tags") {
                    HStack(spacing: 4) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
    }

    private func dueText(_ due: Date) -> String {
        let date = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard item.isOverdue else { return date }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: due),
                                                   to: Calendar.current.startOfDay(for: .now)).day ?? 0
        return days > 0 ? "\(date) · \(days) day\(days == 1 ? "" : "s") late" : date
    }

    // MARK: - Subtasks

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtasks").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(item.completedSubtaskCount) of \(item.subtaskCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(item.orderedSubtasks, id: \.uuid) { subtask in
                SubtaskLine(subtask: subtask, size: 16, fontSize: 12.5, editable: false)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            let updated = item.lastUpdated
            Text("Updated \(updated.date.formatted(.relative(presentation: .named)))\(updated.actor.map { " by \($0)" } ?? "")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onOpenWindow) {
                Text("Open in Window")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open this card in its own window (⌘O)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }
}
