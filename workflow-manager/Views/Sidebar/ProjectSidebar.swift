//
//  ProjectSidebar.swift
//  workflow-manager
//
//  Workspace › Folder › … › Project › View, every level foldable. The layout is
//  design/ClaudeWM.fig › SB.
//
//  Built on a ScrollView + VStack rather than a `List`, on purpose: `List` never
//  animates row height, so a fold just popped. Here a section's rows live in a
//  VStack whose height animates, which reads as a real accordion. The cost is
//  that selection, drag-and-drop and the sidebar look are hand-rolled instead
//  of coming from `List` — see `SidebarRow`.
//
//  Folds are remembered in `UserDefaults`, not in the store: they are a viewing
//  state, and writing them into SwiftData would put every fold on the undo
//  stack and wake the board sync for nothing.
//

import SwiftUI
import SwiftData
import AppKit

struct ProjectSidebar: View {
    @Environment(\.modelContext) private var context
    /// Optional so previews without the store don't trap.
    @Environment(TerminalStateStore.self) private var terminalStore: TerminalStateStore?

    @Binding var destination: AppDestination
    @Binding var viewMode: BoardViewMode
    /// Whether Phone Access and the MCP server are serving, for the footer.
    var isSharing: Bool = false
    var isMCPRunning: Bool = false

    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Query(sort: \ProjectFolder.sortOrder) private var folders: [ProjectFolder]

    @State private var editorTarget: ProjectEditorTarget?
    /// Set when "New Project Here…" opened the editor, so the new project lands
    /// in that folder.
    @State private var newProjectFolder: ProjectFolder?
    @State private var openError: String?
    @State private var isOpeningFolder = false
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""
    @State private var folderToDelete: ProjectFolder?
    @State private var dropTargetKey: String?
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool

    /// Things open by default that the user closed: workspaces, folders, Pinned,
    /// and the open project's view list.
    @AppStorage("sidebar.closed") private var closedRaw = ""
    /// Things closed by default that the user opened: Archived.
    @AppStorage("sidebar.opened") private var openedRaw = ""

    // MARK: - Derived

    private var workspaces: [ProjectFolder] {
        folders.filter { $0.parent == nil && !$0.isDeleted }
    }

    private var liveProjects: [Project] {
        projects.filter { !$0.isDeleted && $0.status != .archived }
    }

    private var unfiled: [Project] {
        liveProjects.filter { $0.folder == nil }
    }

    private var pinned: [Project] {
        liveProjects.filter(\.isPinned)
    }

    private var archived: [Project] {
        projects.filter { !$0.isDeleted && $0.status == .archived }
    }

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            filterField
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if isFiltering {
                        filterResults
                    } else {
                        tree
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .overlay {
            if projects.isEmpty && folders.isEmpty {
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
        .sheet(item: $editorTarget, onDismiss: { newProjectFolder = nil }) { target in
            ProjectEditorSheet(target: target) { project in
                if case .new = target, let folder = newProjectFolder {
                    project.folder = folder
                }
                open(project)
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
        .alert(
            folderPrompt?.title ?? "",
            isPresented: .init(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })
        ) {
            TextField("Name", text: $folderName)
            Button(folderPrompt?.confirmTitle ?? "OK") { commitFolderPrompt() }
            Button("Cancel", role: .cancel) { folderPrompt = nil }
        } message: {
            Text(folderPrompt?.message ?? "")
        }
        .confirmationDialog(
            "Delete “\(folderToDelete?.displayName ?? "")”?",
            isPresented: .init(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    withAnimation(.snappy) { SidebarMutations.delete(folder, context: context) }
                }
                folderToDelete = nil
            }
        } message: {
            Text("Its projects and folders move up a level. No project is deleted.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProjectRequested)) { _ in
            editorTarget = .new
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFolderRequested)) { _ in
            openProjectFolder()
        }
        .task {
            SidebarMutations.adoptLegacyGroups(in: context)
        }
        // AppKit makes the window's first text field its initial first
        // responder, so every launch opened with the filter focused and ringed.
        // `.defaultFocus(_, false)` does not override that, and resigning in
        // `onAppear` loses a race with the window becoming key.
        .background(InitialFocusResigner())
    }

    // MARK: - Filter

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter \(liveProjects.count) projects", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onSubmit { filterMatches.first.map(open) }
                .onExitCommand { filterText = ""; filterFocused = false }
            if isFiltering {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘⇧F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(filterFocused ? Color.accentColor : Theme.hairline,
                              lineWidth: filterFocused ? 2 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background {
            // ⌘⇧F from anywhere in the window.
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private var filterMatches: [Project] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return projects.filter { project in
            guard !project.isDeleted else { return false }
            return project.name.lowercased().contains(needle)
                || project.summary.lowercased().contains(needle)
                || (project.repoSlug?.lowercased().contains(needle) ?? false)
                || (project.folder?.path.contains { $0.name.lowercased().contains(needle) } ?? false)
        }
    }

    /// Matches grouped under their folder path. Parents stay as context — a
    /// project called "api" means little without the client it belongs to.
    @ViewBuilder
    private var filterResults: some View {
        let matches = filterMatches
        let groups = Dictionary(grouping: matches) { location(of: $0) }
        Text(matches.count == 1 ? "1 project" : "\(matches.count) projects")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        ForEach(groups.keys.sorted(), id: \.self) { path in
            Text(path)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: Theme.Sidebar.headerHeight)
                .padding(.top, 6)
            ForEach(groups[path] ?? [], id: \.uuid) { project in
                projectNode(project, depth: 0, expandable: false)
            }
        }
        if matches.isEmpty {
            Text("No project matches “\(filterText)”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func location(of project: Project) -> String {
        if project.status == .archived { return "Archived" }
        guard let folder = project.folder else { return "No Folder" }
        return folder.path.map(\.displayName).joined(separator: " › ")
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        smartRows

        if !pinned.isEmpty {
            let open = isOpen("pinned")
            SidebarSectionHeader(title: "Pinned", isOpen: open) { toggle("pinned") }
            if open {
                ForEach(pinned, id: \.uuid) { project in
                    projectNode(project, depth: 0, expandable: false)
                }
            }
        }

        ForEach(workspaces, id: \.uuid) { workspace in
            workspaceSection(workspace)
        }

        if !unfiled.isEmpty {
            if workspaces.isEmpty {
                Color.clear.frame(height: 8)
            } else {
                let open = isOpen("unfiled")
                SidebarSectionHeader(title: "No Folder", symbol: "tray", count: unfiled.count, isOpen: open) {
                    toggle("unfiled")
                }
                .dropDestination(for: String.self) { payloads, _ in
                    drop(payloads, into: nil)
                }
            }
            if workspaces.isEmpty || isOpen("unfiled") {
                ForEach(unfiled, id: \.uuid) { project in
                    projectNode(project, depth: 0)
                }
            }
        }

        if !archived.isEmpty {
            let open = openedKeys.contains("archived")
            SidebarSectionHeader(title: "Archived", symbol: "archivebox", count: archived.count, isOpen: open) {
                toggleOpened("archived")
            }
            if open {
                ForEach(archived, id: \.uuid) { project in
                    projectNode(project, depth: 0, expandable: false)
                }
            }
        }
    }

    @ViewBuilder
    private var smartRows: some View {
        smartRow(.overview, title: "Overview", symbol: "square.grid.2x2", tint: Theme.link, count: nil)
        smartRow(.queue(.agents), title: CardQueue.agents.title, symbol: CardQueue.agents.symbol,
                 tint: Theme.agent, count: CardQueue.agents.count(in: projects), dot: Theme.agent)
        smartRow(.queue(.review), title: CardQueue.review.title, symbol: CardQueue.review.symbol,
                 tint: Theme.warning, count: CardQueue.review.count(in: projects))
        smartRow(.queue(.overdue), title: CardQueue.overdue.title, symbol: CardQueue.overdue.symbol,
                 tint: Theme.danger, count: CardQueue.overdue.count(in: projects))
    }

    private func smartRow(
        _ target: AppDestination,
        title: String,
        symbol: String,
        tint: Color,
        count: Int?,
        dot: Color? = nil
    ) -> some View {
        let selected = destination == target
        return SidebarRow(isSelected: selected, title: title) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : tint)
        } accessory: {
            if let count, count > 0 {
                HStack(spacing: 5) {
                    if let dot { Circle().fill(selected ? .white : dot).frame(width: 6, height: 6) }
                    Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
        }
        .onTapGesture { destination = target }
    }

    // MARK: - Workspaces and folders

    @ViewBuilder
    private func workspaceSection(_ workspace: ProjectFolder) -> some View {
        let key = workspace.uuid.uuidString
        let open = isOpen(key)
        let contained = workspace.allProjects.filter { $0.status != .archived }
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionHeader(
                title: workspace.displayName,
                symbol: "building.2",
                count: contained.count,
                isOpen: open,
                onToggle: { toggle(key) }
            ) {
                if !open {
                    let rollup = FolderRollup(projects: contained, terminals: terminalStore)
                    HStack(spacing: 3) {
                        if rollup.agents > 0 { Circle().fill(Theme.agent).frame(width: 5, height: 5) }
                        if rollup.running > 0 { Circle().fill(Theme.running).frame(width: 5, height: 5) }
                        if rollup.late > 0 { Circle().fill(Theme.danger).frame(width: 5, height: 5) }
                    }
                }
            }
            .background(dropHighlight(key), in: .rect(cornerRadius: 6))
            .contextMenu { folderMenu(workspace) }
            .draggable("folder:\(key)")
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, into: workspace)
            } isTargeted: { setDropTarget(key, $0) }

            if open {
                folderContents(workspace, depth: 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func folderContents(_ folder: ProjectFolder, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 1) {
                ForEach(folder.orderedChildren, id: \.uuid) { child in
                    folderNode(child, depth: depth)
                }
                ForEach(folder.orderedProjects.filter { $0.status != .archived }, id: \.uuid) { project in
                    projectNode(project, depth: depth)
                }
            }
        )
    }

    /// A folder row and, when open, everything in it. `AnyView` because the
    /// tree is recursive and an opaque type cannot contain itself.
    private func folderNode(_ folder: ProjectFolder, depth: Int) -> AnyView {
        let key = folder.uuid.uuidString
        let open = isOpen(key)
        let contained = folder.allProjects.filter { $0.status != .archived }
        let rollup = FolderRollup(projects: contained, terminals: terminalStore)
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(
                    depth: depth,
                    disclosure: open ? .open : .closed,
                    onDisclosure: { toggle(key) },
                    title: folder.displayName,
                    subtitle: open || rollup.isEmpty ? nil : AnyView(rollup.view)
                ) {
                    Image(systemName: open ? "folder" : "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.link)
                } accessory: {
                    Text("\(contained.count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .background(dropHighlight(key), in: .rect(cornerRadius: 6))
                .onTapGesture { withAnimation(.smooth(duration: 0.25)) { toggle(key) } }
                .contextMenu { folderMenu(folder) }
                .draggable("folder:\(key)")
                .dropDestination(for: String.self) { payloads, _ in
                    drop(payloads, into: folder)
                } isTargeted: { setDropTarget(key, $0) }

                if open {
                    folderContents(folder, depth: depth + 1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        )
    }

    // MARK: - Projects

    /// A project row and, if it is the open project, its views.
    ///
    /// Only the open project expands: with dozens of projects, a tree where
    /// every project can show four children is a tree nobody can scan.
    private func projectNode(_ project: Project, depth: Int, expandable: Bool = true) -> AnyView {
        let key = "p:\(project.uuid.uuidString)"
        let isOpenProject = destination.projectID == project.uuid
        let expanded = expandable && isOpenProject && isOpen(key)
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(
                    depth: depth,
                    disclosure: expandable ? (expanded ? .open : .closed) : .placeholder,
                    isSelected: isOpenProject && !expanded && expandable,
                    isEmphasized: isOpenProject && (expanded || !expandable),
                    onDisclosure: {
                        if isOpenProject { toggle(key) } else { open(project) }
                    },
                    title: project.name.isEmpty ? "Untitled Project" : project.name
                ) {
                    ProjectBadge(project: project)
                } accessory: {
                    projectSignals(project)
                }
                .background(dropHighlight(key), in: .rect(cornerRadius: 6))
                .onTapGesture { open(project) }
                .contextMenu { projectMenu(project) }
                .draggable("project:\(project.uuid.uuidString)")
                .dropDestination(for: String.self) { payloads, _ in
                    drop(payloads, onto: project)
                } isTargeted: { setDropTarget(key, $0) }

                if expanded {
                    ForEach(views(for: project)) { mode in
                        viewRow(mode, of: project, depth: depth + 1)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        )
    }

    /// One signal per state, in the dot vocabulary: Claude at work, commands
    /// running, then either done or a done/total count.
    @ViewBuilder
    private func projectSignals(_ project: Project) -> some View {
        let agents = project.allItems.count { $0.agentState == .working }
        let running = terminalStore?.model(for: project.uuid).runningCount ?? 0
        HStack(spacing: 5) {
            if agents > 0 {
                Circle().fill(Theme.agent).frame(width: 6, height: 6)
                    .help("Claude is working on \(agents) card\(agents == 1 ? "" : "s")")
            }
            if running > 0 {
                Circle().fill(Theme.running).frame(width: 6, height: 6)
                    .help("\(running) command\(running == 1 ? "" : "s") running")
            }
            if project.status == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.running)
            } else if project.totalCount > 0 {
                Text("\(project.completedCount)/\(project.totalCount)")
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
        }
    }

    /// The views worth listing under a project. List and Timeline are other
    /// layouts of the same cards, so they share the Board row.
    private func views(for project: Project) -> [BoardViewMode] {
        var modes: [BoardViewMode] = [.board, .issues]
        if project.hasRepository { modes += [.terminal, .files] }
        return modes
    }

    private func viewRow(_ mode: BoardViewMode, of project: Project, depth: Int) -> some View {
        let selected = destination.projectID == project.uuid && viewMode.sidebarGroup == mode
        let running = terminalStore?.model(for: project.uuid).runningCount ?? 0
        return SidebarRow(
            depth: depth,
            height: Theme.Sidebar.viewRowHeight,
            disclosure: .placeholder,
            isSelected: selected,
            title: mode.title
        ) {
            Image(systemName: mode.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        } accessory: {
            switch mode {
            case .board:
                Text("\(project.openCount) open").font(.system(size: 11))
            case .terminal where running > 0:
                HStack(spacing: 5) {
                    Circle().fill(selected ? .white : Theme.running).frame(width: 6, height: 6)
                    Text("\(running) running").font(.system(size: 11))
                }
            default:
                EmptyView()
            }
        }
        .onTapGesture {
            destination = .project(project.uuid)
            if viewMode.sidebarGroup != mode { viewMode = mode }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    newProjectFolder = nil
                    editorTarget = .new
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.link)
                        Text(isOpeningFolder ? "Opening…" : "New Project")
                            .font(.system(size: 13))
                        Spacer(minLength: 4)
                        Text("⌘N").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: Theme.Sidebar.rowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isOpeningFolder)

                Menu {
                    Button("Open Project Folder…") { openProjectFolder() }
                    Divider()
                    Button("New Workspace…") { beginFolderPrompt(.newFolder(parent: nil, moving: nil)) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 6)
                .help("Open a folder, or add a workspace")
            }

            Divider().padding(.horizontal, 8)

            settingsRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// Settings, carrying what is listening: the MCP server and Phone Access.
    private var settingsRow: some View {
        let selected = destination == .settings
        let services = [isMCPRunning ? "MCP" : nil, isSharing ? "Phone" : nil].compactMap { $0 }
        return SidebarRow(isSelected: selected, title: "Settings") {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        } accessory: {
            if !services.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(selected ? .white : Theme.running).frame(width: 6, height: 6)
                    Text(services.joined(separator: " · "))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.running))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background((selected ? Color.white : Theme.running).opacity(0.16), in: .capsule)
            }
        }
        .onTapGesture { destination = .settings }
    }

    // MARK: - Menus

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Open Board") { open(project, mode: .board) }
        Button("Open Issues") { open(project, mode: .issues) }
        if project.hasRepository {
            Button("Open Terminal") { open(project, mode: .terminal) }
            Button("Reveal in Finder") {
                if let directory = project.repoDirectory {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
            Divider()
            Button("Run All Commands") { startAllCommands(project) }
                .disabled(!hasRunnableCommands(project))
            if terminalStore?.model(for: project.uuid).hasRunning == true {
                Button("Stop All Commands") { terminalStore?.model(for: project.uuid).stopAll() }
            }
        }

        Divider()
        Button(project.isPinned ? "Unpin" : "Pin to Sidebar") {
            withAnimation(.snappy) { project.isPinned.toggle() }
        }
        Menu("Move to") {
            Button(project.folder == nil ? "✓ No Folder" : "No Folder") {
                withAnimation(.snappy) { SidebarMutations.move(project, into: nil, siblings: unfiled) }
            }
            Divider()
            ForEach(folderChoices(), id: \.folder.uuid) { choice in
                Button(choiceLabel(choice, current: project.folder)) {
                    withAnimation(.snappy) {
                        SidebarMutations.move(project, into: choice.folder, siblings: choice.folder.orderedProjects)
                    }
                }
            }
        }
        Button("New Folder with Project…") {
            beginFolderPrompt(.newFolder(parent: project.folder, moving: project))
        }

        Divider()
        Button("Edit…") { editorTarget = .edit(project) }
        Button("Duplicate") { BoardMutations.duplicate(project, in: context, existing: projects) }
        Menu("Status") {
            ForEach(ProjectStatus.allCases) { status in
                Button(project.status == status ? "✓ \(status.title)" : status.title) {
                    withAnimation(.snappy) { project.status = status }
                }
            }
        }

        Divider()
        Button("Delete Project", role: .destructive) { delete(project) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: ProjectFolder) -> some View {
        Button("New Project Here…") {
            newProjectFolder = folder
            editorTarget = .new
        }
        Button("New Folder…") { beginFolderPrompt(.newFolder(parent: folder, moving: nil)) }

        Divider()
        Button("Rename…") { beginFolderPrompt(.rename(folder)) }
        Menu("Move to") {
            Button(folder.isWorkspace ? "✓ Top Level" : "Top Level") {
                withAnimation(.snappy) { SidebarMutations.move(folder, into: nil, context: context) }
            }
            Divider()
            ForEach(folderChoices(excluding: folder), id: \.folder.uuid) { choice in
                Button(choiceLabel(choice, current: folder.parent)) {
                    withAnimation(.snappy) { SidebarMutations.move(folder, into: choice.folder, context: context) }
                }
            }
        }
        Divider()
        Button(folder.isWorkspace ? "Delete Workspace…" : "Delete Folder…", role: .destructive) {
            folderToDelete = folder
        }
    }

    /// Every folder, depth-first, for "Move to". A folder being moved is left
    /// out along with everything under it.
    private func folderChoices(excluding moving: ProjectFolder? = nil) -> [(folder: ProjectFolder, depth: Int)] {
        func walk(_ folder: ProjectFolder, _ depth: Int) -> [(folder: ProjectFolder, depth: Int)] {
            if let moving, moving.contains(folder) { return [] }
            return [(folder, depth)] + folder.orderedChildren.flatMap { walk($0, depth + 1) }
        }
        return workspaces.flatMap { walk($0, 0) }
    }

    private func choiceLabel(_ choice: (folder: ProjectFolder, depth: Int), current: ProjectFolder?) -> String {
        let indent = String(repeating: "    ", count: choice.depth)
        let mark = choice.folder.uuid == current?.uuid ? "✓ " : ""
        return indent + mark + choice.folder.displayName
    }

    // MARK: - Drag and drop

    /// Payloads are `project:<uuid>` or `folder:<uuid>` strings. `Transferable`
    /// types would be tidier, but a plain string is what `.draggable` already
    /// uses for projects elsewhere and needs no exported type declaration.
    private func drop(_ payloads: [String], into folder: ProjectFolder?) -> Bool {
        dropTargetKey = nil
        guard let payload = payloads.first else { return false }
        withAnimation(.snappy(duration: 0.22)) {
            if let project = draggedProject(payload) {
                SidebarMutations.move(project, into: folder, siblings: folder?.orderedProjects ?? unfiled)
            } else if let dragged = draggedFolder(payload) {
                SidebarMutations.move(dragged, into: folder, context: context)
            }
        }
        if let folder { reveal(folder) }
        return true
    }

    private func drop(_ payloads: [String], onto target: Project) -> Bool {
        dropTargetKey = nil
        guard let payload = payloads.first else { return false }
        withAnimation(.snappy(duration: 0.22)) {
            if let project = draggedProject(payload) {
                let siblings = target.folder?.orderedProjects ?? unfiled
                SidebarMutations.move(project, before: target, siblings: siblings)
            } else if let dragged = draggedFolder(payload) {
                SidebarMutations.move(dragged, into: target.folder, context: context)
            }
        }
        return true
    }

    private func draggedProject(_ payload: String) -> Project? {
        guard payload.hasPrefix("project:") else { return nil }
        let id = payload.dropFirst("project:".count)
        return projects.first { $0.uuid.uuidString == id }
    }

    private func draggedFolder(_ payload: String) -> ProjectFolder? {
        guard payload.hasPrefix("folder:") else { return nil }
        let id = payload.dropFirst("folder:".count)
        return folders.first { $0.uuid.uuidString == id }
    }

    private func setDropTarget(_ key: String, _ targeted: Bool) {
        if targeted { dropTargetKey = key } else if dropTargetKey == key { dropTargetKey = nil }
    }

    private func dropHighlight(_ key: String) -> AnyShapeStyle {
        dropTargetKey == key ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Color.clear)
    }

    // MARK: - Folds

    private var closedKeys: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }
    private var openedKeys: Set<String> { Set(openedRaw.split(separator: ",").map(String.init)) }

    private func isOpen(_ key: String) -> Bool { !closedKeys.contains(key) }

    private func toggle(_ key: String) {
        var keys = closedKeys
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        closedRaw = keys.sorted().joined(separator: ",")
    }

    private func toggleOpened(_ key: String) {
        var keys = openedKeys
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        openedRaw = keys.sorted().joined(separator: ",")
    }

    /// Opens every folder above `folder` and the folder itself, so whatever
    /// was just moved or selected there is visible.
    private func reveal(_ folder: ProjectFolder?) {
        guard let folder else { return }
        var keys = closedKeys
        for ancestor in folder.path { keys.remove(ancestor.uuid.uuidString) }
        closedRaw = keys.sorted().joined(separator: ",")
    }

    // MARK: - Actions

    private func open(_ project: Project) {
        destination = .project(project.uuid)
        reveal(project.folder)
    }

    private func open(_ project: Project, mode: BoardViewMode) {
        open(project)
        viewMode = mode
    }

    private func beginFolderPrompt(_ prompt: FolderPrompt) {
        if case .rename(let folder) = prompt { folderName = folder.name } else { folderName = "" }
        folderPrompt = prompt
    }

    private func commitFolderPrompt() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { folderPrompt = nil }
        guard !name.isEmpty, let prompt = folderPrompt else { return }
        withAnimation(.snappy) {
            switch prompt {
            case .newFolder(let parent, let moving):
                let folder = SidebarMutations.createFolder(named: name, in: parent, context: context)
                if let moving { SidebarMutations.move(moving, into: folder, siblings: []) }
                reveal(folder)
            case .rename(let folder):
                folder.name = name
            }
        }
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
            open(existing, mode: .issues)
            return
        }

        isOpeningFolder = true
        Task {
            defer { isOpeningFolder = false }
            // A plain folder (no `.git`, or no `origin`) still opens for the
            // board, terminal, files and Claude. Only a resolved remote gets the
            // Issues view, so only then do we jump to it.
            let repository = try? await GitHubCLI.repository(at: directory)
            let project: Project
            if let repository {
                project = BoardMutations.createProject(
                    forRepository: repository, at: directory, in: context, existing: projects
                )
            } else {
                project = BoardMutations.createProject(
                    forFolderAt: directory, in: context, existing: projects
                )
            }
            open(project, mode: repository != nil ? .issues : .board)
        }
    }

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
        if destination.projectID == project.uuid { destination = .overview }
        context.delete(project)
    }
}

/// The name prompt shared by New Folder, New Workspace and Rename.
enum FolderPrompt {
    /// `parent == nil` makes a workspace. `moving` is a project to file in the
    /// new folder straight away.
    case newFolder(parent: ProjectFolder?, moving: Project?)
    case rename(ProjectFolder)

    var title: String {
        switch self {
        case .newFolder(nil, _): "New Workspace"
        case .newFolder: "New Folder"
        case .rename(let folder): folder.isWorkspace ? "Rename Workspace" : "Rename Folder"
        }
    }

    var confirmTitle: String {
        if case .rename = self { return "Rename" }
        return "Create"
    }

    var message: String {
        switch self {
        case .newFolder(nil, _):
            "A top-level section — a client, a company, or Personal."
        case .newFolder(let parent?, let moving):
            moving.map { "A folder in “\(parent.displayName)” holding “\($0.name)”." }
                ?? "A folder in “\(parent.displayName)”."
        case .rename:
            ""
        }
    }
}

extension BoardViewMode {
    /// The sidebar row a mode lights up: List and Timeline are layouts of the
    /// board's cards, so they light Board.
    var sidebarGroup: BoardViewMode {
        switch self {
        case .board, .list, .timeline: .board
        default: self
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var destination: AppDestination = .overview
    @Previewable @State var mode: BoardViewMode = .board
    NavigationSplitView {
        ProjectSidebar(destination: $destination, viewMode: $mode)
    } detail: {
        Text("Detail")
    }
    .modelContainer(SampleData.container)
    .frame(width: 900, height: 700)
}
#endif

/// Clears the text-field focus AppKit hands out when a window first becomes
/// key, once. Later focus — ⌘⇧F, a click — is left alone.
private struct InitialFocusResigner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResignerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ResignerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            // Already key: resign now, and never again — coming back to the
            // app later must not take away focus the user gave the field.
            if window.isKeyWindow { return resign(in: window) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resignOnce() }
            }
        }

        private func resignOnce() {
            guard let window else { return }
            resign(in: window)
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func resign(in window: NSWindow) {
            DispatchQueue.main.async {
                if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            }
        }
    }
}
