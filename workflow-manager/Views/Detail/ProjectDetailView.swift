//
//  ProjectDetailView.swift
//  workflow-manager
//
//  There is no separate header row: the window title bar already names the
//  project, so the icon, description and live metrics live in the toolbar and
//  the board gets everything below it.
//

import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow

    @Bindable var project: Project
    @Binding var viewMode: BoardViewMode
    @Binding var filter: BoardFilter
    @Binding var selectedItemID: UUID?
    var focus: FocusState<FocusPane?>.Binding

    @State private var editorTarget: ProjectEditorTarget?
    @State private var showsOverview = false
    @State private var wantsEditAfterOverview = false
    /// From the app-level coordinator, for the same reason the terminal
    /// sessions are: this view is recreated on every project switch, and sync
    /// that stops when you look away is sync that silently does not happen.
    @Environment(WorkflowSyncCoordinator.self) private var syncCoordinator
    @State private var showsContractSheet = false
    /// From an app-level store, not owned here: this view is recreated on every
    /// project switch, so owning the sessions would kill a running dev server
    /// the moment you look at another project. The store outlives that.
    @Environment(TerminalStateStore.self) private var terminalStore

    private var terminals: TerminalSessionsModel { terminalStore.model(for: project.uuid) }

    private var selectedItem: WorkItem? {
        guard let selectedItemID else { return nil }
        return project.allItems.first { $0.uuid == selectedItemID }
    }

    /// Under the title: the repository when there is one — it is what tells
    /// two projects called "api" apart — else the description, else the goal.
    private var subtitle: String {
        if let slug = project.repoSlug { return slug }
        if !project.summary.isEmpty { return project.summary }
        if !project.goal.isEmpty { return project.goal }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewMode.requiresRepository {
                ScopeBar(project: project, filter: $filter)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ProjectStatusBar(project: project, runningCount: terminals.runningCount)
            }
            .navigationTitle(project.name.isEmpty ? "Untitled Project" : project.name)
            .navigationSubtitle(subtitle)
            .searchable(text: $filter.searchText, prompt: "Search cards")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showsOverview) {
                // Opening the editor from `onDismiss` avoids presenting two
                // sheets in the same frame, which SwiftUI drops.
                if wantsEditAfterOverview {
                    wantsEditAfterOverview = false
                    editorTarget = .edit(project)
                }
            } content: {
                ProjectOverviewSheet(project: project) { wantsEditAfterOverview = true }
            }
            .sheet(item: $editorTarget) { target in
                ProjectEditorSheet(target: target)
            }
            .sheet(isPresented: $showsContractSheet) {
                WorkflowContractSheet(project: project)
            }
            .environment(syncCoordinator.model(for: project))
            // Turning sync on or off, or relinking the repository, changes which
            // engines should be running. The coordinator otherwise reconciles
            // itself on every save, with no help from this view.
            .task(id: syncKey) {
                syncCoordinator.reconcile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newItemRequested)) { _ in
                addItemToFirstColumn()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteItemRequested)) { _ in
                deleteInspectedItem()
            }
            .onReceive(NotificationCenter.default.publisher(for: .startClaudeForItem)) { note in
                startClaudeSession(from: note)
            }
    }

    /// Restarts the watcher when the thing being watched changes — the project,
    /// its repository, or whether syncing is on at all.
    private var syncKey: String {
        "\(project.uuid)|\(project.repoPath ?? "")|\(project.isSyncing)"
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .board:
            BoardView(
                project: project,
                selectedItemID: $selectedItemID,
                filter: filter,
                focus: focus,
                onOpenItem: open
            )
        case .list:
            ProjectItemsTable(project: project, selectedItemID: $selectedItemID, filter: filter,
                              focus: focus, onOpen: open)
        case .timeline:
            ProjectTimelineView(project: project, selectedItemID: $selectedItemID, filter: filter, onOpen: open)
        case .issues:
            GitHubIssuesView(project: project, searchText: filter.searchText)
        case .terminal:
            if project.hasRepository {
                TerminalView(project: project, sessions: terminals)
            } else {
                needsRepository(
                    title: "No Repository Linked",
                    message: "Link this project to a folder to save and run its commands."
                )
            }
        case .files:
            if let directory = project.repoDirectory {
                FilesView(root: directory, accent: project.accent.color, focus: focus)
            } else {
                needsRepository(
                    title: "No Repository Linked",
                    message: "Link this project to a folder to browse its files."
                )
            }
        }
    }

    private func needsRepository(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Choose Repository…") { viewMode = .issues }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Every item here is a plain system control, so the toolbar's Liquid
        // Glass draws all the chrome. Anything carrying its own background or
        // padding ends up as a pill inside a glass pill — which is what the
        // first pass of this redesign did.
        ToolbarItem(placement: .navigation) {
            Button {
                showsOverview = true
            } label: {
                Label("Project Details", systemImage: project.symbolName)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(project.accent.color)
            .help("Show goal, plan and timeline")
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $viewMode) {
                ForEach(BoardViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        if let chip = agentChip {
            ToolbarItem {
                // Toggles the board to Claude's cards — a chip that only
                // reported a number would be a control that does nothing.
                Button {
                    filter.scope = filter.scope == .claude ? .all : .claude
                } label: {
                    Label(chip, systemImage: "sparkles")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.agentText)
                .help(filter.scope == .claude ? "Show every card" : "Show only cards with Claude")
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }

        if !viewMode.requiresRepository {
            ToolbarItem {
                Button {
                    addItemToFirstColumn()
                } label: {
                    Label("New Card", systemImage: "plus")
                }
                .help("New card in its own window (⇧⌘N)")
            }
        }

        ToolbarItem {
            Menu {
                Button("Project Details…") { showsOverview = true }
                Button("Edit Project…") { editorTarget = .edit(project) }
                Divider()
                // Linking and unlinking both live in the Issues view, which is
                // the only place the repository is meaningful.
                Button(project.repoSlug.map { "Repository: \($0)" } ?? "Link Repository…") {
                    viewMode = .issues
                }
                if project.hasRepository {
                    Divider()
                    // Turning sync on is the moment a role-less board becomes a
                    // problem, so it is also the moment to fix one. Written as a
                    // custom binding rather than `.onChange` because this Toggle
                    // lives in a Menu, which tears its content down as it closes.
                    Toggle("Sync Board with Claude", isOn: Binding(
                        get: { project.workflowSyncEnabled },
                        set: { enabled in
                            project.workflowSyncEnabled = enabled
                            if enabled { BoardMutations.adoptDefaultRoles(for: project) }
                        }
                    ))
                    Button("Set Up Claude Contract…") { showsContractSheet = true }
                    if project.workflowSyncEnabled, let warning = syncMappingWarning {
                        Text(warning)
                    }
                }

                Divider()
                Menu("Status") {
                    ForEach(ProjectStatus.allCases) { status in
                        Button(project.status == status ? "✓ \(status.title)" : status.title) {
                            project.status = status
                        }
                    }
                }
            } label: {
                Label("Project Actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Project actions")
        }
    }

    /// Why a board with sync switched on is not actually syncing, or is only
    /// half-mapped.
    ///
    /// Naming the missing statuses matters more than it looks: a card Claude
    /// moves to a status no column carries simply does not move, which is
    /// indistinguishable from the agent having ignored the card.
    private var syncMappingWarning: String? {
        let missing = ColumnRole.allCases.filter { project.column(for: $0) == nil }
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.title).formatted(.list(type: .and))
        guard project.hasSyncRoles else {
            return "Not syncing: no column carries a Claude Status. Set one from a column’s menu."
        }
        return "\(names): no column carries this status, so Claude cannot move a card there."
    }

    /// "Claude · 1 working", or "· 2 queued" when nothing is in progress yet.
    private var agentChip: String? {
        let items = project.allItems
        let working = items.count { $0.agentState == .working }
        let queued = items.count { $0.agentState == .queued }
        if working > 0 { return "Claude · \(working) working" }
        if queued > 0 { return "Claude · \(queued) queued" }
        return nil
    }

    // MARK: - Actions

    /// ⇧⌘N and the toolbar's +: a blank card in the first column, opened in
    /// its own window with the caret in the title. Closing it untouched
    /// discards it.
    private func addItemToFirstColumn() {
        guard let column = project.orderedColumns.first else { return }
        let item = BoardMutations.addItem(titled: "", to: column, in: context)
        selectedItemID = item.uuid
        open(item)
    }

    private func open(_ item: WorkItem) {
        openWindow(id: CardWindow.sceneID, value: item.uuid)
    }

    private func deleteInspectedItem() {
        guard let selectedItem else { return }
        selectedItemID = nil
        withAnimation(.snappy) { context.delete(selectedItem) }
    }

    /// Opens a Claude session in the Terminal for the card named in the
    /// notification, then brings that tab forward.
    private func startClaudeSession(from note: Notification) {
        guard let raw = note.userInfo?["itemID"] as? String,
              let uuid = UUID(uuidString: raw),
              let item = project.allItems.first(where: { $0.uuid == uuid }),
              let directory = project.repoDirectory
        else { return }

        let name = item.title.isEmpty ? "Untitled" : item.title
        terminals.startClaudeSession(
            title: "Claude · \(name)",
            prompt: claudePrompt(for: item),
            in: directory
        )
        selectedItemID = nil
        viewMode = .terminal
    }

    /// The first message Claude gets: the card, as plainly as possible. Notes
    /// are capped so a very long card can't produce an unwieldy command line.
    private func claudePrompt(for item: WorkItem) -> String {
        var lines = [
            "Work on this task from the project board.",
            "",
            "Title: \(item.title.isEmpty ? "Untitled" : item.title)",
        ]
        if let number = item.githubIssueNumber {
            lines.append("GitHub issue: #\(number)")
        }
        let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(String(details.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
#Preview {
    @Previewable @State var mode: BoardViewMode = .board
    @Previewable @State var filter = BoardFilter()
    @Previewable @State var inspected: UUID?
    @Previewable @FocusState var focus: FocusPane?

    if let project = SampleData.firstProject {
        NavigationStack {
            ProjectDetailView(
                project: project,
                viewMode: $mode,
                filter: $filter,
                selectedItemID: $inspected,
                focus: $focus
            )
        }
        .modelContainer(SampleData.container)
        .environment(FilesStateStore())
        .environment(TerminalStateStore())
        .frame(width: 1150, height: 720)
    }
}
#endif
