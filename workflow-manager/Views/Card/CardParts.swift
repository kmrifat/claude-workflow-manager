//
//  CardParts.swift
//  workflow-manager
//
//  What the card popover and the card window share, so the two say the same
//  thing about a card: its column, its Claude state, and how a subtask is
//  ticked. Design: design/ClaudeWM.fig › Cards · Popover & Editor.
//

import SwiftUI
import SwiftData

// MARK: - Actions

@MainActor
enum CardActions {
    /// The card can reach Claude: through `tasks.json` on a syncing board, or
    /// over MCP.
    static func claudeIsReachable(_ item: WorkItem, mcp: MCPServer?) -> Bool {
        guard let project = item.project else { return false }
        return project.isSyncing || mcp?.isEnabled == true
    }

    /// Requesting is the user's decision (an app-owned field). Only a syncing
    /// board has a `tasks.json` to rewrite; over MCP the agent reads the board.
    static func setRequested(_ requested: Bool, on item: WorkItem, sync: WorkflowSyncModel?, context: ModelContext) {
        item.workflowRequested = requested
        if let project = item.project, project.isSyncing, let sync {
            Task { await sync.writeNow(for: project, context: context) }
        }
    }

    static func addSubtask(titled title: String, to item: WorkItem, context: ModelContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let subtask = Subtask(title: trimmed, sortOrder: FractionalOrder.afterLast(of: item.subtasks.map(\.sortOrder)))
        context.insert(subtask)
        subtask.item = item
    }

    /// A note lands in the card's activity, where `get_card` hands it to the
    /// agent — the board as the conversation, not a side channel.
    static func addNote(_ text: String, to item: WorkItem, context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let event = CardEvent(actor: "You", tool: nil, summary: "Added a note", note: trimmed)
        context.insert(event)
        event.item = item
    }

    static func headline(for state: AgentState) -> String {
        switch state {
        case .queued:   "Queued for Claude"
        case .working:  "Claude is working"
        case .inReview: "Claude opened it for review"
        case .done:     "Done with Claude"
        case .none:     ""
        }
    }

    static func detail(for item: WorkItem) -> String? {
        if let name = item.agentName, let claimed = item.agentClaimedAt {
            return "\(name) · claimed \(claimed.formatted(.relative(presentation: .named)))"
        }
        // Only a card nobody has picked up yet is waiting for a session.
        if item.workflowRequested, item.agentState == .queued {
            return item.project?.isSyncing == true
                ? "Waiting for a session to pick it up from tasks.json"
                : "Waiting for a session to claim it over MCP"
        }
        return nil
    }
}

extension WorkItem {
    /// Nothing anyone typed or attached. A card window closed in this state is
    /// discarded, the way Notes drops an empty note.
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subtasks.isEmpty
            && events.isEmpty
            && githubIssueNumber == nil
            && !workflowRequested
            && tags.isEmpty
            && owner.isEmpty
            && dueDate == nil
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// Newest activity, else creation: what "Updated …" means on a card.
    var lastUpdated: (date: Date, actor: String?) {
        let latest = events.filter { !$0.isDeleted }.max { $0.date < $1.date }
        return latest.map { ($0.date, $0.actor) } ?? (createdAt, nil)
    }
}

extension Priority {
    var chipColor: Color {
        switch self {
        case .urgent: Theme.danger
        case .high:   Theme.warning
        case .normal: .secondary
        case .low:    .secondary
        }
    }
}

// MARK: - Column menu

/// Where the card is, as a menu of where it can go.
struct CardColumnMenu: View {
    let item: WorkItem
    var large = false

    var body: some View {
        Menu {
            ForEach(item.project?.orderedColumns ?? [], id: \.uuid) { column in
                Button {
                    withAnimation(.snappy) { BoardMutations.append(item, to: column) }
                } label: {
                    if column.uuid == item.column?.uuid {
                        Label(column.name, systemImage: "checkmark")
                    } else {
                        Text(column.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(item.column?.tint ?? .gray).frame(width: large ? 8 : 7, height: large ? 8 : 7)
                Text(item.column?.name ?? "No column")
                    .font(.system(size: large ? 12.5 : 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: large ? 8 : 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, large ? 0 : 8)
            .frame(height: large ? nil : 22)
            .background(large ? Color.clear : Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move to another column")
    }
}

// MARK: - Checkbox

/// The Notes checkbox: a ring, or an accent disc with a tick.
struct RoundCheckbox: View {
    let isOn: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .contentShape(.circle)
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

/// One subtask: tick it, or rename it in place.
struct SubtaskLine: View {
    @Bindable var subtask: Subtask
    var size: CGFloat = 18
    var fontSize: CGFloat = 15
    var editable = true
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button { subtask.isDone.toggle() } label: { RoundCheckbox(isOn: subtask.isDone, size: size) }
                .buttonStyle(.plain)
                .accessibilityLabel(subtask.isDone ? "Mark not done" : "Mark done")
            if editable {
                TextField("Subtask", text: $subtask.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundStyle(subtask.isDone ? .secondary : .primary)
            } else {
                Text(subtask.title)
                    .font(.system(size: fontSize))
                    .foregroundStyle(subtask.isDone ? .secondary : .primary)
                    .lineLimit(2)
            }
        }
        .contextMenu {
            if let onDelete { Button("Delete Subtask", role: .destructive, action: onDelete) }
        }
    }
}

// MARK: - Claude

/// A card's Claude state, as one callout. Empty when Claude has nothing to do
/// with the card.
struct CardClaudeCallout: View {
    let item: WorkItem
    var compact = false

    var body: some View {
        let state = item.agentState
        if state != .none {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.agent).frame(width: 6, height: 6)
                    Text(CardActions.headline(for: state))
                        .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                        .foregroundStyle(Theme.agentText)
                    Spacer(minLength: 4)
                    if let pr = item.workflowPRURL, let url = URL(string: pr) {
                        Link(item.pullRequestNumber.map { "PR #\($0)" } ?? "Pull request", destination: url)
                            .font(.system(size: compact ? 11 : 12, weight: .medium))
                    }
                    if let last = item.events.filter({ $0.tool != nil }).max(by: { $0.date < $1.date }) {
                        Text(last.date, format: .relative(presentation: .named))
                            .font(.system(size: compact ? 10.5 : 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = summary {
                    Text(detail)
                        .font(.system(size: compact ? 11.5 : 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(compact ? 10 : 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.agent.opacity(0.08), in: .rect(cornerRadius: compact ? 8 : 10))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10).strokeBorder(Theme.agent.opacity(0.22))
            }
        }
    }

    /// The latest thing the agent said it did, else who claimed it, plus the
    /// branch it is on.
    private var summary: String? {
        let said = item.events
            .filter { $0.tool != nil && !$0.isDeleted }
            .max { $0.date < $1.date }?.summary
        let parts = [said ?? CardActions.detail(for: item), item.workflowBranch.map { "branch \($0)" }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}
