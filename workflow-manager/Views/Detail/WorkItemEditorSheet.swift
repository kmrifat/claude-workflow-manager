//
//  WorkItemEditorSheet.swift
//  workflow-manager
//
//  The full editor for a board card, as a resizable modal rather than a side
//  drawer. Two panes: notes on the left with a GitHub-style Write/Preview toggle
//  (the preview is the same `IssueMarkdownView` a GitHub issue body uses), and
//  the card's attributes — priority, dates, tags, checklist, links — on the
//  right. The popover stays the glance; this is where the long-form editing
//  happens.
//

import SwiftUI
import SwiftData

struct WorkItemEditorSheet: View {
    @Environment(\.modelContext) private var context
    /// Optional so a host that doesn't provide one — a preview, or any future
    /// call site — degrades to hiding the Claude controls instead of trapping.
    @Environment(WorkflowSyncModel.self) private var sync: WorkflowSyncModel?

    @Bindable var item: WorkItem
    var accent: Color = .accentColor
    var onClose: () -> Void

    @State private var notesMode: NotesMode = .write
    @State private var newSubtask = ""
    @State private var newTag = ""
    @State private var hasStartDate = false
    @State private var hasDueDate = false
    @State private var isPickingIssue = false
    @State private var isPickingBlocker = false

    private enum NotesMode: String, CaseIterable, Identifiable {
        case write = "Write"
        case preview = "Preview"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                notesPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                detailsForm
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 400, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: 720, idealWidth: 900, maxWidth: .infinity,
            minHeight: 520, idealHeight: 640, maxHeight: .infinity
        )
        .onExitCommand(perform: onClose)
        .onAppear(perform: syncDateToggles)
        .onChange(of: item.uuid) { _, _ in syncDateToggles() }
        .onChange(of: hasStartDate) { _, enabled in
            if enabled, item.startDate == nil { item.startDate = .now }
            if !enabled { item.startDate = nil }
        }
        .onChange(of: hasDueDate) { _, enabled in
            if enabled, item.dueDate == nil { item.dueDate = .now }
            if !enabled { item.dueDate = nil }
        }
        .sheet(isPresented: $isPickingIssue) {
            if let project = item.project {
                IssuePickerSheet(
                    project: project,
                    claimed: IssueLinking.linkedNumbers(in: project),
                    currentSelection: item.githubIssueNumber,
                    onPick: { IssueLinking.link(item, to: $0) }
                )
            }
        }
        .sheet(isPresented: $isPickingBlocker) {
            BlockerPickerSheet(candidates: eligibleBlockers) { chosen in
                if !item.blockedBy.contains(where: { $0.uuid == chosen.uuid }) {
                    item.blockedBy.append(chosen)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                TextField("Title", text: $item.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1...2)

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

            Spacer(minLength: 0)

            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: - Notes

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: $notesMode) {
                    ForEach(NotesMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                if notesMode == .write {
                    TextEditor(text: $item.details)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                } else if item.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview.")
                        .font(.system(size: 12.5))
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(14)
                } else {
                    ScrollView {
                        IssueMarkdownView(markdown: item.details, accent: accent)
                            .padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    // MARK: - Details form

    private var detailsForm: some View {
        Form {
            Section("Attributes") {
                Picker("Priority", selection: priorityBinding) {
                    ForEach(Priority.allCases) { priority in
                        Label(priority.title, systemImage: priority.symbol).tag(priority)
                    }
                }

                TextField("Owner", text: $item.owner, prompt: Text("Initials or name"))
            }

            dependenciesSection

            if let project = item.project, project.hasRepository {
                claudeLaunchSection
                githubSection(for: project)
                if project.isSyncing, let sync {
                    claudeSection(for: project, sync: sync)
                }
            }

            Section("Dates") {
                Toggle("Start date", isOn: $hasStartDate)
                if hasStartDate {
                    DatePicker(
                        "Starts",
                        selection: Binding(get: { item.startDate ?? .now }, set: { item.startDate = $0 }),
                        displayedComponents: .date
                    )
                }

                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: Binding(get: { item.dueDate ?? .now }, set: { item.dueDate = $0 }),
                        displayedComponents: .date
                    )
                    if item.isOverdue {
                        Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Tags") {
                if !item.tags.isEmpty {
                    WrappingTags(tags: item.tags) { tag in
                        item.tags.removeAll { $0 == tag }
                    }
                }
                TextField("Add tag", text: $newTag)
                    .onSubmit(addTag)
            }

            Section {
                ForEach(item.orderedSubtasks, id: \.uuid) { subtask in
                    SubtaskRow(subtask: subtask) {
                        context.delete(subtask)
                    }
                }
                TextField("Add subtask", text: $newSubtask)
                    .onSubmit(addSubtask)
            } header: {
                HStack {
                    Text("Checklist")
                    Spacer()
                    if !item.subtasks.isEmpty {
                        Text("\(item.completedSubtaskCount)/\(item.subtasks.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Delete Item", role: .destructive) {
                    onClose()
                    context.delete(item)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dependencies

    /// Cards this one waits on. Local to the board — an ordering aid for the
    /// human, not something the agent is told about.
    private var dependenciesSection: some View {
        Section {
            if item.blockedBy.isEmpty {
                Text("Not blocked by anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(item.blockedBy, id: \.uuid) { blocker in
                    HStack(spacing: 8) {
                        Image(systemName: blocker.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(blocker.isDone ? .green : .orange)
                        Text(blocker.title.isEmpty ? "Untitled" : blocker.title)
                            .lineLimit(1)
                            .strikethrough(blocker.isDone, color: .secondary)
                            .foregroundStyle(blocker.isDone ? .secondary : .primary)
                        Spacer(minLength: 0)
                        Button {
                            item.blockedBy.removeAll { $0.uuid == blocker.uuid }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("Add Blocker…") { isPickingBlocker = true }
                .disabled(eligibleBlockers.isEmpty)
        } header: {
            HStack {
                Text("Blocked By")
                Spacer()
                if item.isBlocked {
                    Label("\(item.openBlockers.count) open", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Every card in this project that could still become a blocker — excludes
    /// self, existing blockers, and anything downstream (which would cycle).
    private var eligibleBlockers: [WorkItem] {
        guard let project = item.project else { return [] }
        return project.allItems
            .filter { item.canBeBlocked(by: $0) }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    // MARK: - Claude session

    /// Launches a per-card Claude session in the Terminal. Posts a notification
    /// rather than reaching for the terminal model directly — `ProjectDetailView`
    /// owns that, resolves the card, seeds the prompt and switches tabs.
    private var claudeLaunchSection: some View {
        Section("Claude Session") {
            Button {
                NotificationCenter.default.post(
                    name: .startClaudeForItem,
                    object: nil,
                    userInfo: ["itemID": item.uuid.uuidString]
                )
                onClose()
            } label: {
                Label("Start Claude Session…", systemImage: "sparkles")
            }

            if item.isBlocked {
                Label(
                    "This card is blocked by \(item.openBlockers.count) unfinished item\(item.openBlockers.count == 1 ? "" : "s").",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Text("Opens `claude` in the Terminal tab, in this project's repository, seeded with the card's title and notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The card's link to a GitHub issue.
    ///
    /// Shown only for projects with a linked repository — an issue number is
    /// meaningless without one to resolve it against.
    @ViewBuilder
    private func githubSection(for project: Project) -> some View {
        Section("GitHub") {
            if let number = item.githubIssueNumber {
                LabeledContent("Issue", value: "#\(number)")

                if let url = item.githubIssueURL {
                    Link("Open on GitHub", destination: url)
                } else {
                    Label(
                        "Linked to \(item.githubRepoSlug ?? "another repository"), which this project is no longer connected to.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Change…") { isPickingIssue = true }
                    Button("Unlink", role: .destructive) { IssueLinking.unlink(item) }
                }
            } else {
                Button("Link to Issue…") { isPickingIssue = true }
            }
        }
    }

    /// Sending a card to Claude, and whatever the agent has reported back.
    ///
    /// "Send" writes `requested: true` into `.taskboard/tasks.json` immediately
    /// — the agent picks work up from there, because `claude remote-control`
    /// has no way to be handed a task directly.
    @ViewBuilder
    private func claudeSection(for project: Project, sync: WorkflowSyncModel) -> some View {
        Section("Claude") {
            if item.workflowRequested {
                LabeledContent("Status", value: "Waiting for a session to pick this up")
                Button("Cancel Request") {
                    item.workflowRequested = false
                    Task { await sync.writeNow(for: project, context: context) }
                }
            } else {
                Button("Send to Claude") {
                    item.workflowRequested = true
                    Task { await sync.writeNow(for: project, context: context) }
                }
                .disabled(item.isBlocked)
                if item.isBlocked {
                    Text("Resolve this card's blockers before handing it to a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let branch = item.workflowBranch {
                LabeledContent("Branch", value: branch)
            }
            if let prUrl = item.workflowPRURL, let url = URL(string: prUrl) {
                Link("Open Pull Request", destination: url)
            }
        }
    }

    // MARK: - Helpers

    private var priorityBinding: Binding<Priority> {
        Binding(get: { item.priority }, set: { item.priority = $0 })
    }

    private func syncDateToggles() {
        hasStartDate = item.startDate != nil
        hasDueDate = item.dueDate != nil
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !item.tags.contains(trimmed) else {
            newTag = ""
            return
        }
        item.tags.append(trimmed)
        newTag = ""
    }

    private func addSubtask() {
        let trimmed = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let subtask = Subtask(
            title: trimmed,
            sortOrder: FractionalOrder.afterLast(of: item.subtasks.map(\.sortOrder))
        )
        context.insert(subtask)
        subtask.item = item
        newSubtask = ""
    }
}

/// Picks another card to add as a blocker. The candidate list is already
/// filtered to what is safe to add (no self, no duplicates, no cycles).
private struct BlockerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [WorkItem]
    var onPick: (WorkItem) -> Void

    @State private var query = ""

    private var filtered: [WorkItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { $0.matches(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Blocker")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Eligible Cards",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Other cards in this project can be added here, as long as they don't create a cycle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.uuid) { candidate in
                    Button {
                        onPick(candidate)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: candidate.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(candidate.isDone ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.title.isEmpty ? "Untitled" : candidate.title)
                                    .lineLimit(1)
                                if let column = candidate.column {
                                    Text(column.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $query, prompt: "Search cards")
            }
        }
        .frame(width: 420, height: 480)
    }
}

private struct SubtaskRow: View {
    @Bindable var subtask: Subtask
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $subtask.isDone) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField("Subtask", text: $subtask.title)
                .textFieldStyle(.plain)
                .strikethrough(subtask.isDone, color: .secondary)
                .foregroundStyle(subtask.isDone ? .secondary : .primary)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Simple flow layout for tag chips.
private struct WrappingTags: View {
    let tags: [String]
    var onRemove: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(tags)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(stride(from: 0, to: tags.count, by: 3)), id: \.self) { start in
                    row(Array(tags[start..<min(start + 3, tags.count)]))
                }
            }
        }
    }

    private func row(_ slice: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(slice, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
            }
            Spacer(minLength: 0)
        }
    }
}
