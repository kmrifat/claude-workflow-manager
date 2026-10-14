//
//  CardWindow.swift
//  workflow-manager
//
//  A card in its own window — design/ClaudeWM.fig › C02, and C03 for a new
//  card. It replaced both the card inspector and the editor sheet, for three
//  reasons a sheet could not meet: the board stays live behind it (a sheet
//  freezes the window it belongs to), several cards can be open side by side,
//  and the window can be any size, full screen included.
//
//  It writes like Notes: a date line, the title as the first and largest
//  line, the fields as chips, then the notes — Markdown, styled as it is typed
//  by `MarkdownTextView`. There is no Save: every keystroke is the card. A
//  window closed on a card nobody put anything in discards it, as Notes drops
//  an empty note.
//
//  Keyed by the card's UUID (`openWindow(id:value:)`), so opening a card that
//  is already open brings its window forward.
//

import SwiftUI
import SwiftData

struct CardWindow: View {
    static let sceneID = "card"

    let itemID: UUID?

    @Environment(\.modelContext) private var context
    @Environment(WorkflowSyncCoordinator.self) private var syncCoordinator
    @Query private var matches: [WorkItem]

    init(itemID: UUID?) {
        self.itemID = itemID
        let id = itemID ?? UUID()
        _matches = Query(filter: #Predicate<WorkItem> { $0.uuid == id })
    }

    private var item: WorkItem? { matches.first { !$0.isDeleted } }

    var body: some View {
        Group {
            if let item, let project = item.project {
                CardPage(item: item)
                    .environment(syncCoordinator.model(for: project))
                    .onDisappear { discardIfBlank(item) }
            } else {
                ContentUnavailableView(
                    "Card Not Found",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("It was deleted, or it belongs to a board that is gone.")
                )
                .frame(minWidth: 420, minHeight: 300)
            }
        }
    }

    /// Nothing typed, nothing attached: the card goes, as an empty note does.
    private func discardIfBlank(_ item: WorkItem) {
        guard !item.isDeleted, item.isBlank else { return }
        context.delete(item)
    }
}

// MARK: - Page

struct CardPage: View {
    @Bindable var item: WorkItem

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkflowSyncModel.self) private var sync: WorkflowSyncModel?
    @Environment(MCPServer.self) private var mcp: MCPServer?

    @State private var editor = MarkdownEditorController()
    @FocusState private var titleFocused: Bool
    @State private var newSubtask = ""
    @FocusState private var newSubtaskFocused: Bool
    @State private var showsActivity = false
    @State private var note = ""
    @State private var creatingIssue = false
    @State private var linkingIssue = false
    @State private var addingBlocker = false
    @State private var confirmsDelete = false
    @State private var repositoryLabels: [String] = []

    private var project: Project? { item.project }

    private var events: [CardEvent] {
        item.events.filter { !$0.isDeleted }.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dateLine
                    .padding(.bottom, 12)
                TextField("Title", text: $item.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .focused($titleFocused)
                    .onSubmit { editor.focus() }
                    .onKeyPress(.downArrow) {
                        editor.focus()
                        return .handled
                    }
                    .padding(.bottom, 12)
                CardFields(
                    item: item,
                    onCreateIssue: { creatingIssue = true },
                    onLinkIssue: { linkingIssue = true },
                    onAddBlocker: { addingBlocker = true }
                )
                .padding(.bottom, 16)
                if item.agentState != .none {
                    CardClaudeCallout(item: item)
                        .padding(.bottom, 20)
                }
                MarkdownTextView(
                    text: $item.details,
                    placeholder: "Notes. Markdown works as you type — # for a heading, - for a list, [ ] for a checklist, ``` for code.",
                    controller: editor,
                    onExitTop: { titleFocused = true }
                )
                .padding(.bottom, 26)
                subtasks
                    .padding(.bottom, 22)
                activity
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background {
            // Clicking the empty page below the notes puts the caret in them,
            // the way Notes treats its whole page as the note.
            Color(nsColor: .textBackgroundColor).opacity(0.0001)
                .onTapGesture { editor.focus() }
        }
        .background(.background)
        .background {
            // AppKit makes the title — the window's first text field — first
            // responder and selects it. Right for a new card, wrong for one
            // you opened to read.
            if !item.isBlank { InitialFocusResigner() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .navigationTitle(item.title.isEmpty ? "New Card" : item.title)
        // The title is the page's first line; the toolbar repeating it, as
        // Notes does not, would put it on screen twice. The window keeps it
        // for the Window menu and Mission Control.
        .hidingToolbarTitle()
        .toolbar { toolbar }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            // A new card starts in its title, as a new note does.
            if item.title.isEmpty { titleFocused = true }
            await loadLabels()
        }
        .sheet(isPresented: $creatingIssue) {
            if let project {
                CreateIssueSheet(item: item, project: project, availableLabels: repositoryLabels) { created in
                    IssueLinking.link(item, toIssueNumber: created.number, slug: project.repoSlug)
                }
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
        .sheet(isPresented: $addingBlocker) {
            BlockerPickerSheet(candidates: eligibleBlockers) { blocker in
                item.blockedBy.append(blocker)
            }
        }
        .confirmationDialog("Delete “\(item.displayTitle)”?", isPresented: $confirmsDelete) {
            Button("Delete Card", role: .destructive) {
                context.delete(item)
                dismiss()
            }
        } message: {
            Text("This can be undone with ⌘Z in the board's window.")
        }
    }

    // MARK: - Header

    private var dateLine: some View {
        Group {
            if item.isBlank, let column = item.column {
                Text("New card · \(column.name) in \(project?.name ?? "")")
            } else {
                Text(item.createdAt.formatted(date: .long, time: .shortened))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subtasks

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !item.orderedSubtasks.isEmpty {
                HStack {
                    Text("Subtasks").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(item.completedSubtaskCount) of \(item.subtaskCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(item.orderedSubtasks, id: \.uuid) { subtask in
                    SubtaskLine(subtask: subtask, size: 20) {
                        withAnimation(.snappy) { context.delete(subtask) }
                    }
                }
            }
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                TextField("New subtask", text: $newSubtask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($newSubtaskFocused)
                    .onSubmit {
                        CardActions.addSubtask(titled: newSubtask, to: item, context: context)
                        newSubtask = ""
                        // Return keeps you here for the next one, as a list does.
                        newSubtaskFocused = true
                    }
            }
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        let reachable = CardActions.claudeIsReachable(item, mcp: mcp)
        if !events.isEmpty || reachable {
            DisclosureGroup(isExpanded: $showsActivity) {
                VStack(alignment: .leading, spacing: 12) {
                    if reachable {
                        HStack(spacing: 8) {
                            TextField("Note for Claude…", text: $note, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .lineLimit(1...5)
                                .onSubmit(addNote)
                            if !note.isEmpty {
                                Button("Add", action: addNote)
                                    .controlSize(.small)
                                    .keyboardShortcut(.return, modifiers: .command)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
                    }
                    ForEach(events.prefix(50), id: \.uuid) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(event.tool == nil ? Color.accentColor : Theme.agent)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Text(event.actor).bold()) \(event.summary.lowercasedFirst)")
                                    .font(.system(size: 13))
                                if let note = event.note {
                                    Text(note)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text([event.tool, event.date.formatted(.relative(presentation: .named))]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11.5, design: event.tool == nil ? .default : .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Text("Activity").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    if let summary = activitySummary {
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy) { showsActivity.toggle() } }
            }
        }
    }

    private var activitySummary: String? {
        guard let latest = events.first else { return nil }
        let count = events.count == 1 ? "1 update" : "\(events.count) updates"
        return "\(count) · last by \(latest.actor) \(latest.date.formatted(.relative(presentation: .named)))"
    }

    private func addNote() {
        CardActions.addNote(note, to: item, context: context)
        note = ""
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(item.isBlank ? "Saved as you type · closing an empty card discards it" : "\(wordCount) words · saved")
            Spacer()
            Text("Markdown  ·  ⌘B bold  ·  ⌘I italic  ·  ⇧⌘L checklist")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var wordCount: Int {
        (item.title + " " + item.details).split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            CardColumnMenu(item: item, large: true)
        }
        if let project {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    ProjectBadge(project: project, size: 16)
                    Text(project.name).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .help("In \(project.name)")
            }
        }

        ToolbarItemGroup {
            Menu {
                Button("Title") { editor.setHeading(1) }
                Button("Heading") { editor.setHeading(2) }
                Button("Subheading") { editor.setHeading(3) }
                Button("Body") { editor.setHeading(0) }
                Divider()
                Button("Bold  ⌘B") { editor.toggleBold() }
                Button("Italic  ⌘I") { editor.toggleItalic() }
                Button("Strikethrough  ⇧⌘X") { editor.toggleStrikethrough() }
                Button("Inline Code") { editor.toggleInlineCode() }
                Divider()
                Button("Bulleted List") { editor.insertBulletList() }
                Button("Quote") { editor.insertQuote() }
                Button("Link  ⌘K") { editor.insertLink() }
            } label: {
                Label("Format", systemImage: "textformat")
            }
            .help("Format")
            Button { editor.toggleChecklist() } label: {
                Label("Checklist", systemImage: "checklist")
            }
            .help("Checklist (⇧⌘L)")
            Button { editor.insertCodeBlock() } label: {
                Label("Code Block", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Code block (⌥⌘C)")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItem { claudeButton }

        ToolbarItem {
            Menu {
                if project?.repoSlug != nil {
                    if item.githubIssueNumber == nil {
                        Button("Create GitHub Issue…") { creatingIssue = true }
                        Button("Link to Existing Issue…") { linkingIssue = true }
                    } else {
                        if let url = item.githubIssueURL { Link("Open Issue on GitHub", destination: url) }
                        Button("Unlink Issue") { IssueLinking.unlink(item) }
                    }
                    Divider()
                }
                Button("Add Blocker…") { addingBlocker = true }
                Button("Duplicate") { BoardMutations.duplicate(item, in: context) }
                Divider()
                Button("Delete Card…", role: .destructive) { confirmsDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
    }

    @ViewBuilder
    private var claudeButton: some View {
        let state = item.agentState
        if state == .queued && item.workflowRequested {
            Menu {
                Button("Cancel Request") {
                    CardActions.setRequested(false, on: item, sync: sync, context: context)
                }
            } label: {
                Label("Queued for Claude", systemImage: "sparkles")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.agentText)
            .menuIndicator(.hidden)
        } else if state == .working {
            Label("Claude working", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.agentText)
        } else if state == .none, !item.isDone, CardActions.claudeIsReachable(item, mcp: mcp) {
            Button {
                CardActions.setRequested(true, on: item, sync: sync, context: context)
            } label: {
                Label("Send to Claude", systemImage: "sparkles")
            }
            .labelStyle(.titleAndIcon)
            .disabled(item.isBlocked || item.title.isEmpty)
            .help(item.isBlocked ? "Blocked by unfinished cards" : "Flag this card for Claude to pick up")
        }
    }

    // MARK: - Helpers

    private var eligibleBlockers: [WorkItem] {
        guard let project else { return [] }
        return project.allItems
            .filter { item.canBeBlocked(by: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func loadLabels() async {
        guard let project, project.hasRepository else { return }
        // From the cache only — opening a card must not spawn `gh`.
        let issues = await IssueCache.load(for: project, in: context)?.issues ?? []
        repositoryLabels = Set(issues.flatMap { $0.labels.map(\.name) }).sorted()
    }
}

extension String {
    /// "Moved to Review" → "moved to Review", after an actor's name.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
