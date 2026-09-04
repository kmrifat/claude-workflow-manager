//
//  ProjectSidebar.swift
//  workflow-manager
//
//  Built on a ScrollView + VStack rather than a `List`, on purpose: `List` never
//  animates row height, so a collapsing group just popped. Here a group's rows
//  live in a VStack whose height animates, which reads as a real accordion. The
//  cost is that selection, drag-reorder and the sidebar look are hand-rolled
//  instead of coming from `List` — see `projectRow`.
//

import SwiftUI
import SwiftData

struct ProjectSidebar: View {
    @Environment(\.modelContext) private var context
    /// Optional so previews without the store don't trap; the run-all menu items
    /// just stay hidden there.
    @Environment(TerminalStateStore.self) private var terminalStore: TerminalStateStore?
    @Binding var selection: UUID?

    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @State private var editorTarget: ProjectEditorTarget?
    @State private var openError: String?
    @State private var isOpeningFolder = false
    /// The project waiting for a new group name, and the field it types into.
    @State private var projectForNewGroup: Project?
    @State private var newGroupName = ""
    /// Groups the user has collapsed. In memory: expansion is a viewing state,
    /// not something worth persisting.
    @State private var collapsedGroups: Set<String> = []

    // Grouped in memory: project counts are tiny, and it avoids putting the
    // status raw string through a `#Predicate`.
    private var active: [Project] {
        projects.filter { $0.status != .completed && $0.status != .archived }
    }
    private var completed: [Project] {
        projects.filter { $0.status == .completed }
    }
    private var archived: [Project] {
        projects.filter { $0.status == .archived }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                activeContent
                statusSection("Completed", completed)
                statusSection("Archived", archived)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Create a project, or open a folder that already has a Git repository.")
                } actions: {
                    Button("New Project…") { editorTarget = .new }
                    Button("Open Project Folder…") { openProjectFolder() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Menu {
                addMenuItems
            } label: {
                Label(isOpeningFolder ? "Opening…" : "Add Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .disabled(isOpeningFolder)
            .padding(8)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    addMenuItems
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .disabled(isOpeningFolder)
                .help("Create a project, or open a repository folder")
            }
        }
        .sheet(item: $editorTarget) { target in
            ProjectEditorSheet(target: target) { project in
                selection = project.uuid
            }
        }
        .alert(
            "Couldn’t Open That Folder",
            isPresented: .init(get: { openError != nil }, set: { if !$0 { openError = nil } })
        ) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProjectRequested)) { _ in
            editorTarget = .new
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFolderRequested)) { _ in
            openProjectFolder()
        }
        .alert(
            "New Group",
            isPresented: .init(
                get: { projectForNewGroup != nil },
                set: { if !$0 { projectForNewGroup = nil } }
            )
        ) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { projectForNewGroup?.groupName = trimmed }
                projectForNewGroup = nil
            }
            Button("Cancel", role: .cancel) { projectForNewGroup = nil }
        } message: {
            Text("Put “\(projectForNewGroup?.name ?? "")” into a new group.")
        }
    }

    /// No `keyboardShortcut` here on purpose: the File menu already binds ⌘N and
    /// ⌘O app-wide, and binding them a second time inside this menu would race —
    /// ⌘O could open two panels.
    @ViewBuilder
    private var addMenuItems: some View {
        Button("New Project…") { editorTarget = .new }
        Button("Open Project Folder…") { openProjectFolder() }
    }

    /// Picks a folder, resolves it through `gh`, and creates a project already
    /// linked to it — then lands on Issues, which is the point of opening a
    /// repository rather than creating an empty project.
    ///
    /// Opening a folder that is already open selects it instead of making a
    /// second project for the same clone.
    private func openProjectFolder() {
        guard !isOpeningFolder else { return }
        guard let directory = RepositoryPicker.chooseDirectory() else { return }

        let path = Project.canonicalRepoPath(directory)
        if let existing = projects.first(where: { $0.repoPath == path }) {
            selection = existing.uuid
            showIssues()
            return
        }

        isOpeningFolder = true
        Task {
            defer { isOpeningFolder = false }
            // Try to resolve a GitHub remote, but don't require one: a plain
            // folder (no `.git`, or a repo without `origin`) still opens for the
            // board, terminal, files and Claude. Only a resolved remote gets the
            // Issues view, so only then do we jump to it.
            let repository = try? await GitHubCLI.repository(at: directory)
            let project: Project
            if let repository {
                project = BoardMutations.createProject(
                    forRepository: repository,
                    at: directory,
                    in: context,
                    existing: projects
                )
            } else {
                project = BoardMutations.createProject(
                    forFolderAt: directory,
                    in: context,
                    existing: projects
                )
            }
            selection = project.uuid
            if repository != nil { showIssues() }
        }
    }

    private func showIssues() {
        NotificationCenter.default.post(
            name: .boardViewModeRequested,
            object: nil,
            userInfo: ["mode": BoardViewMode.issues.rawValue]
        )
    }

    // MARK: - Sections

    /// The non-finished lifecycle statuses. Ungrouped projects are sectioned by
    /// these so changing a project's status actually moves it — before, Planning
    /// and On Hold were lumped into one "Active" section and looked inert.
    private static let activeStatuses: [ProjectStatus] = [.planning, .active, .onHold]

    @ViewBuilder
    private var activeContent: some View {
        // User groups first — an explicit organization that wins over status.
        ForEach(namedActiveGroups, id: \.name) { group in
            groupSection(group.name, group.projects)
        }
        // Then everything ungrouped, split by lifecycle status so each has a home.
        ForEach(Self.activeStatuses) { status in
            statusSection(status.title, ungroupedActive.filter { $0.status == status })
        }
    }

    /// A plain, always-open section: a header and its rows.
    @ViewBuilder
    private func statusSection(_ title: String, _ slice: [Project]) -> some View {
        if !slice.isEmpty {
            sectionHeader(title)
            ForEach(slice, id: \.uuid) { project in
                projectRow(project, in: slice)
            }
        }
    }

    /// A named group: collapsible, with an always-visible trailing chevron and,
    /// when collapsed, a rollup of the group. Its rows sit in a VStack whose
    /// height animates — the accordion `List` could not do.
    @ViewBuilder
    private func groupSection(_ name: String, _ group: [Project]) -> some View {
        let collapsed = collapsedGroups.contains(name)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { toggleGroup(name) }
            } label: {
                HStack(spacing: 6) {
                    Text(name.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if collapsed { groupSummary(group) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .contentShape(.rect)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 1)
            }
            .buttonStyle(.plain)

            if !collapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group, id: \.uuid) { project in
                        projectRow(project, in: group)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Height animates; clip so rows don't spill past the header mid-slide.
        .clipped()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One project row. Selection, its highlight, and drag-reorder are all done
    /// by hand here — the price of leaving `List` for a real accordion.
    private func projectRow(_ project: Project, in slice: [Project]) -> some View {
        ProjectRow(project: project)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == project.uuid ? Color.accentColor.opacity(0.20) : Color.clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect)
            .onTapGesture { selection = project.uuid }
            .contextMenu { contextMenu(for: project) }
            .draggable(project.uuid.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dragged = slice.first(where: { $0.uuid.uuidString == raw })
                else { return false }
                withAnimation(.snappy(duration: 0.2)) {
                    reorder(slice, moving: dragged, before: project)
                }
                return true
            }
    }

    private func toggleGroup(_ name: String) {
        if collapsedGroups.contains(name) { collapsedGroups.remove(name) }
        else { collapsedGroups.insert(name) }
    }

    // MARK: - Grouping data

    /// Active projects split into user-defined groups, alphabetical, each
    /// preserving `sortOrder`.
    private var namedActiveGroups: [(name: String, projects: [Project])] {
        var buckets: [String: [Project]] = [:]
        for project in active {
            guard let group = project.groupName, !group.isEmpty else { continue }
            buckets[group, default: []].append(project)
        }
        return buckets.keys.sorted().map { ($0, buckets[$0]!) }
    }

    private var ungroupedActive: [Project] {
        active.filter { ($0.groupName ?? "").isEmpty }
    }

    /// Every group name in use, for the "Group" context menu.
    private var existingGroupNames: [String] {
        Set(projects.compactMap(\.groupName).filter { !$0.isEmpty }).sorted()
    }

    /// Minimal rollup for a collapsed group: running commands, in-progress
    /// cards, overdue cards — each a coloured dot with a count, shown only when
    /// non-zero, in the same dot vocabulary the rows use.
    @ViewBuilder
    private func groupSummary(_ group: [Project]) -> some View {
        let running = group.count { terminalStore?.model(for: $0.uuid).hasRunning == true }
        let inProgress = group.reduce(0) { $0 + $1.inProgressCount }
        let overdue = group.reduce(0) { $0 + $1.overdueCount }

        HStack(spacing: 7) {
            if running > 0 {
                summaryDot(.green, running, "\(running) project\(running == 1 ? "" : "s") running commands")
            }
            if inProgress > 0 {
                summaryDot(.blue, inProgress, "\(inProgress) card\(inProgress == 1 ? "" : "s") in progress")
            }
            if overdue > 0 {
                summaryDot(.red, overdue, "\(overdue) overdue card\(overdue == 1 ? "" : "s")")
            }
        }
    }

    private func summaryDot(_ color: Color, _ count: Int, _ help: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    // MARK: - Reordering

    /// Moves `dragged` to just before `target` within a section, re-spacing that
    /// section's `sortOrder`. Values only need to be consistent within the
    /// section, which is how they are rendered.
    private func reorder(_ slice: [Project], moving dragged: Project, before target: Project) {
        guard dragged.uuid != target.uuid else { return }
        var arr = slice.filter { $0.uuid != dragged.uuid }
        guard let index = arr.firstIndex(where: { $0.uuid == target.uuid }) else { return }
        arr.insert(dragged, at: index)
        let orders = FractionalOrder.normalizedOrders(count: arr.count)
        for (project, order) in zip(arr, orders) { project.sortOrder = order }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button("Edit…") { editorTarget = .edit(project) }
        Button("Duplicate") {
            BoardMutations.duplicate(project, in: context, existing: projects)
        }

        if project.hasRepository {
            Divider()
            Button("Run All Commands") { startAllCommands(project) }
                .disabled(!hasRunnableCommands(project))
            if terminalStore?.model(for: project.uuid).hasRunning == true {
                Button("Stop All Commands") { terminalStore?.model(for: project.uuid).stopAll() }
            }
        }

        Divider()
        groupMenu(for: project)
        statusMenu(for: project)

        Divider()
        Button("Delete", role: .destructive) { delete(project) }
    }

    @ViewBuilder
    private func groupMenu(for project: Project) -> some View {
        Menu("Group") {
            ForEach(existingGroupNames, id: \.self) { name in
                Button {
                    project.groupName = name
                } label: {
                    Label(name, systemImage: project.groupName == name ? "checkmark" : "folder")
                }
            }
            if !existingGroupNames.isEmpty { Divider() }
            Button("New Group…") {
                newGroupName = ""
                projectForNewGroup = project
            }
            if project.groupName != nil {
                Button("Remove from Group") { project.groupName = nil }
            }
        }
    }

    @ViewBuilder
    private func statusMenu(for project: Project) -> some View {
        Menu("Status") {
            ForEach(ProjectStatus.allCases) { status in
                Button {
                    project.status = status
                } label: {
                    Label(status.title, systemImage: project.status == status ? "checkmark" : status.symbol)
                }
            }
        }
    }

    // MARK: - Commands

    private func hasRunnableCommands(_ project: Project) -> Bool {
        project.hasRepository
            && project.orderedTerminalCommands.contains(where: \.isIncludedInRunAll)
    }

    private func startAllCommands(_ project: Project) {
        guard let model = terminalStore?.model(for: project.uuid) else { return }
        model.sync(with: project)
        model.runAll(for: project)
    }

    /// Clearing the selection *before* deleting keeps the detail pane from
    /// rendering against a deallocated model object.
    private func delete(_ project: Project) {
        if selection == project.uuid { selection = nil }
        context.delete(project)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selection: UUID?
    NavigationSplitView {
        ProjectSidebar(selection: $selection)
    } detail: {
        Text("Detail")
    }
    .modelContainer(SampleData.container)
    .frame(width: 900, height: 600)
}
#endif
