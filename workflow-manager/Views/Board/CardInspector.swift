//
//  CardInspector.swift
//  workflow-manager
//
//  A selected card, in the window's inspector column — design/ClaudeWM.fig ›
//  W03. It replaced the card popover: a popover covered the cards around the
//  one it described and could not stay open while you worked, and with Claude
//  reporting progress on a card you want that progress in view, not one click
//  away.
//
//  Still a glance plus quick actions, not the whole editor. Long-form editing —
//  both dates, dependencies, tags — stays in `WorkItemEditorSheet` behind
//  "Edit Details…", so there are not two full editors to keep in step.
//
//  Sheets are presented from here directly. That was impossible from the
//  popover (a sheet opened inside a popover is torn down with it as focus
//  moves); an inspector is part of the window, so the constraint is gone.
//

import SwiftUI
import SwiftData

struct CardInspector: View {
    @Bindable var item: WorkItem
    var accent: Color
    var onEditDetails: () -> Void
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(WorkflowSyncModel.self) private var sync: WorkflowSyncModel?
    @Environment(MCPServer.self) private var mcp: MCPServer?

    @State private var note = ""
    @State private var creatingIssue = false
    @State private var linkingIssue = false
    @State private var repositoryLabels: [String] = []
    @State private var confirmsDelete = false
    @FocusState private var noteFocused: Bool

    private var project: Project? { item.project }

    /// The card can reach Claude: the file on a syncing board, or MCP.
    private var claudeIsReachable: Bool {
        guard let project else { return false }
        return project.isSyncing || mcp?.isEnabled == true
    }

    private var events: [CardEvent] {
        item.events.filter { !$0.isDeleted }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    TextField("Title", text: $item.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1...4)
                    claudeBox
                    properties
                    if !item.details.isEmpty {
                        Divider()
                        IssueMarkdownView(markdown: item.details, accent: accent)
                    }
                    if !item.orderedSubtasks.isEmpty {
                        Divider()
                        subtasks
                    }
                    if !events.isEmpty {
                        Divider()
                        activity
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .background(.background)
        .task(id: project?.repoPath) { await loadLabels() }
        .sheet(isPresented: $creatingIssue) {
            if let project {
                CreateIssueSheet(
                    item: item,
                    project: project,
                    availableLabels: repositoryLabels,
                    onCreated: { created in
                        IssueLinking.link(item, toIssueNumber: created.number, slug: project.repoSlug)
                    }
                )
            }
        }
        .sheet(isPresented: $linkingIssue) {
            if let project {
                IssuePickerSheet(
                    project: project,
                    claimed: IssueLinking.linkedNumbers(in: project),
                    currentSelection: item.githubIssueNumber,
                    onPick: { IssueLinking.link(item, to: $0) }
                )
            }
        }
        .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmsDelete) {
            Button("Delete Card", role: .destructive) {
                onClose()
                withAnimation(.snappy) { context.delete(item) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let number = item.githubIssueNumber {
                Text("#\(number)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(item.hasResolvableIssueLink ? .secondary : .tertiary)
            }
            columnMenu
            Spacer(minLength: 4)
            if let url = item.githubIssueURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open the issue on GitHub")
            }
            actionsMenu
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    /// The column as a pop-up: where the card is, and where it can go.
    private var columnMenu: some View {
        Menu {
            ForEach(project?.orderedColumns ?? [], id: \.uuid) { column in
                Button(column.uuid == item.column?.uuid ? "✓ \(column.name)" : column.name) {
                    withAnimation(.snappy) { BoardMutations.append(item, to: column) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(item.column?.tint ?? .gray).frame(width: 7, height: 7)
                Text(item.column?.name ?? "No column")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(item.column?.tint ?? .gray)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background((item.column?.tint ?? .gray).opacity(0.14), in: .rect(cornerRadius: 5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var actionsMenu: some View {
        Menu {
            Button("Edit Details…", action: onEditDetails)
            if project?.hasRepository == true {
                Button("Start Claude Session in Terminal") {
                    NotificationCenter.default.post(
                        name: .startClaudeForItem,
                        object: nil,
                        userInfo: ["itemID": item.uuid.uuidString]
                    )
                }
            }
            if project?.repoSlug != nil {
                Divider()
                if item.githubIssueNumber == nil {
                    // The only action in the app that writes to GitHub. It still
                    // shows exactly what it will file before filing it.
                    Button("Create GitHub Issue…") { creatingIssue = true }
                    Button("Link to Existing Issue…") { linkingIssue = true }
                } else {
                    Button("Unlink Issue") { IssueLinking.unlink(item) }
                }
            }
            Divider()
            Button("Duplicate") { withAnimation(.snappy) { BoardMutations.duplicate(item, in: context) } }
            Button("Delete…", role: .destructive) { confirmsDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Card actions")
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeBox: some View {
        let state = item.agentState
        if state != .none {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.agent.gradient, in: .rect(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agentHeadline(state))
                            .font(.system(size: 13, weight: .semibold))
                        if let detail = agentDetail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let last = events.first(where: { $0.tool != nil }), let tool = last.tool {
                    HStack(spacing: 6) {
                        Text("Last call").foregroundStyle(.secondary)
                        Text(tool).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.agentText)
                        Spacer(minLength: 4)
                        Text(last.date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5))
                }
                HStack(spacing: 6) {
                    if let pr = item.workflowPRURL, let url = URL(string: pr) {
                        Link(destination: url) {
                            Label(item.pullRequestNumber.map { "PR #\($0)" } ?? "Pull Request",
                                  systemImage: "arrow.triangle.pull")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if item.workflowRequested && state == .queued {
                        Button("Cancel Request") { setRequested(false) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.agent.opacity(0.08), in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.agent.opacity(0.25)) }
        } else if claudeIsReachable && !item.isDone {
            HStack(spacing: 8) {
                Button {
                    setRequested(true)
                } label: {
                    Label("Send to Claude", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(item.isBlocked)
                if item.isBlocked {
                    Text("Blocked by unfinished cards.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agentHeadline(_ state: AgentState) -> String {
        switch state {
        case .queued:   "Queued for Claude"
        case .working:  "Claude is working on this"
        case .inReview: "Claude opened it for review"
        case .done:     "Done with Claude"
        case .none:     ""
        }
    }

    private var agentDetail: String? {
        if let name = item.agentName, let claimed = item.agentClaimedAt {
            return "\(name) · claimed \(claimed.formatted(.relative(presentation: .named)))"
        }
        if item.workflowRequested {
            return project?.isSyncing == true
                ? "Waiting for a session to pick it up from tasks.json"
                : "Waiting for a session to claim it over MCP"
        }
        return nil
    }

    /// Requesting is the user's to decide (app-owned). Only a syncing board has
    /// a `tasks.json` to rewrite; over MCP the agent reads the board directly.
    private func setRequested(_ requested: Bool) {
        item.workflowRequested = requested
        if let project, project.isSyncing, let sync {
            Task { await sync.writeNow(for: project, context: context) }
        }
    }

    // MARK: - Properties

    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            propertyRow("Priority") {
                Picker("Priority", selection: Binding(get: { item.priority }, set: { item.priority = $0 })) {
                    ForEach(Priority.allCases) { priority in
                        Label(priority.title, systemImage: priority.symbol).tag(priority)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !item.owner.isEmpty {
                propertyRow("Owner") { Text(item.owner) }
            }
            if let branch = item.workflowBranch {
                propertyRow("Branch") {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let number = item.githubIssueNumber {
                propertyRow("GitHub issue") {
                    if let url = item.githubIssueURL {
                        Link("#\(number)", destination: url)
                    } else {
                        Text("#\(number) in \(item.githubRepoSlug ?? "another repository")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let due = item.dueDate {
                propertyRow("Due") {
                    Text(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .foregroundStyle(item.isOverdue ? Theme.danger : (item.isDueSoon ? Theme.warning : .primary))
                }
            }
            if item.isBlocked {
                propertyRow("Blocked by") {
                    Text(item.openBlockers.map(\.title).formatted(.list(type: .and)))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
            }
            if !item.tags.isEmpty {
                propertyRow("Tags") {
                    HStack(spacing: 4) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(accent.opacity(0.15), in: .rect(cornerRadius: 4))
                                .foregroundStyle(accent)
                        }
                    }
                }
            }
        }
    }

    private func propertyRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            value()
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    // MARK: - Subtasks

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Subtasks").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(item.completedSubtaskCount) of \(item.subtaskCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(item.orderedSubtasks, id: \.uuid) { subtask in
                Toggle(isOn: Binding(get: { subtask.isDone }, set: { subtask.isDone = $0 })) {
                    Text(subtask.title)
                        .font(.system(size: 12))
                        .foregroundStyle(subtask.isDone ? .secondary : .primary)
                }
                .toggleStyle(.checkbox)
                .frame(minHeight: 24)
            }
        }
    }

    // MARK: - Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("via MCP").font(.system(size: 11)).foregroundStyle(Theme.link)
            }
            ForEach(events.prefix(30), id: \.uuid) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(event.tool == nil ? Color.accentColor : Theme.agent)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Text(event.actor).bold()) \(event.summary.lowercasedFirst)")
                            .font(.system(size: 12))
                        if let note = event.note {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text([event.tool, event.date.formatted(.relative(presentation: .named))]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11, design: event.tool == nil ? .default : .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    /// A note to Claude lands in the card's activity, where `get_card` hands it
    /// to the agent — the board as the conversation, not a side channel.
    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Add a note for Claude…", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .focused($noteFocused)
                .onSubmit(addNote)
            if !note.isEmpty {
                Button("Add", action: addNote)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(noteFocused ? Color.accentColor : Theme.hairline, lineWidth: noteFocused ? 2 : 1)
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func addNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let event = CardEvent(actor: "You", tool: nil, summary: "Added a note", note: text)
        context.insert(event)
        event.item = item
        note = ""
    }

    private func loadLabels() async {
        guard let project, project.hasRepository else {
            repositoryLabels = []
            return
        }
        // From the cache only — opening a card must not spawn `gh`.
        let issues = await IssueCache.load(for: project, in: context)?.issues ?? []
        repositoryLabels = Set(issues.flatMap { $0.labels.map(\.name) }).sorted()
    }
}

private extension String {
    /// "Moved to Review" → "moved to Review", after an actor's name.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
