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

    @Bindable var project: Project
    @Binding var viewMode: BoardViewMode
    @Binding var filter: BoardFilter
    @Binding var inspectedItemID: UUID?

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

    private var inspectedItem: WorkItem? {
        guard let inspectedItemID else { return nil }
        return project.allItems.first { $0.uuid == inspectedItemID }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { inspectedItem != nil },
            set: { if !$0 { inspectedItemID = nil } }
        )
    }

    /// Short description in the title bar; falls back to the goal so the
    /// subtitle is rarely empty.
    private var subtitle: String {
        if !project.summary.isEmpty { return project.summary }
        if !project.goal.isEmpty { return project.goal }
        return ""
    }

    var body: some View {
        content
            .navigationTitle(project.name.isEmpty ? "Untitled Project" : project.name)
            .navigationSubtitle(subtitle)
            .searchable(text: $filter.searchText, prompt: "Search items, owners, tags")
            .toolbar { toolbarContent }
            .sheet(isPresented: inspectorPresented) {
                if let inspectedItem {
                    WorkItemEditorSheet(
                        item: inspectedItem,
                        accent: project.accent.color,
                        onClose: { inspectedItemID = nil }
                    )
                }
            }
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
            BoardView(project: project, inspectedItemID: $inspectedItemID, filter: filter)
        case .list:
            ProjectItemsTable(project: project, inspectedItemID: $inspectedItemID, filter: filter)
        case .timeline:
            ProjectTimelineView(project: project, inspectedItemID: $inspectedItemID, filter: filter)
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
                FilesView(root: directory, accent: project.accent.color)
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
        // Sits immediately before the window title, so icon and name read as
        // one unit instead of repeating.
        ToolbarItem(placement: .navigation) {
            Button {
                showsOverview = true
            } label: {
                Image(systemName: project.symbolName)
                    .foregroundStyle(project.accent.color)
            }
            .help("Show goal, plan and timeline")
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $viewMode) {
                ForEach(BoardViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        ToolbarItem {
            Button {
                showsOverview = true
            } label: {
                ProjectMetricsPill(project: project)
            }
            .buttonStyle(.plain)
        }

        // The work-item filters (priority, overdue, owner, tag) mean nothing in
        // the repository-backed modes — there are no work items to filter.
        if !viewMode.requiresRepository {
            ToolbarItem { filterMenu }
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
                    Toggle("Sync Board with Claude", isOn: $project.workflowSyncEnabled)
                    Button("Set Up Claude Contract…") { showsContractSheet = true }
                    if project.workflowSyncEnabled, !project.hasSyncRoles {
                        Text("Assign a Claude Status to at least one column to start syncing.")
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

    private var filterMenu: some View {
        Menu {
            Menu("Minimum Priority") {
                Button(filter.minimumPriority == nil ? "✓ Any" : "Any") {
                    filter.minimumPriority = nil
                }
                ForEach(Priority.allCases.reversed()) { priority in
                    Button(filter.minimumPriority == priority ? "✓ \(priority.title)" : priority.title) {
                        filter.minimumPriority = priority
                    }
                }
            }

            Toggle("Overdue only", isOn: $filter.overdueOnly)

            if !ownerOptions.isEmpty {
                Menu("Owner") {
                    Button(filter.owner == nil ? "✓ Anyone" : "Anyone") { filter.owner = nil }
                    ForEach(ownerOptions, id: \.self) { owner in
                        Button(filter.owner == owner ? "✓ \(owner)" : owner) { filter.owner = owner }
                    }
                }
            }

            if !tagOptions.isEmpty {
                Menu("Tag") {
                    Button(filter.tag == nil ? "✓ Any" : "Any") { filter.tag = nil }
                    ForEach(tagOptions, id: \.self) { tag in
                        Button(filter.tag == tag ? "✓ \(tag)" : tag) { filter.tag = tag }
                    }
                }
            }

            Divider()
            Button("Clear Filters") { filter.clear() }
                .disabled(!filter.isActive)
        } label: {
            Label("Filter", systemImage: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help(filter.isActive ? "Filters are active" : "Filter items")
    }

    private var ownerOptions: [String] {
        Array(Set(project.allItems.map(\.owner).filter { !$0.isEmpty })).sorted()
    }

    private var tagOptions: [String] {
        Array(Set(project.allItems.flatMap(\.tags))).sorted()
    }

    // MARK: - Actions

    private func addItemToFirstColumn() {
        guard let column = project.orderedColumns.first else { return }
        let item = BoardMutations.addItem(titled: "New item", to: column, in: context)
        inspectedItemID = item.uuid
    }

    private func deleteInspectedItem() {
        guard let inspectedItem else { return }
        inspectedItemID = nil
        withAnimation(.snappy) { context.delete(inspectedItem) }
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
        inspectedItemID = nil
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

    if let project = SampleData.firstProject {
        NavigationStack {
            ProjectDetailView(
                project: project,
                viewMode: $mode,
                filter: $filter,
                inspectedItemID: $inspected
            )
        }
        .modelContainer(SampleData.container)
        .environment(FilesStateStore())
        .environment(TerminalStateStore())
        .frame(width: 1150, height: 720)
    }
}
#endif
