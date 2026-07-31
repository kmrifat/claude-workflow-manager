//
//  ProjectSidebar.swift
//  workflow-manager
//

import SwiftUI
import SwiftData

struct ProjectSidebar: View {
    @Environment(\.modelContext) private var context
    @Binding var selection: UUID?

    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @State private var editorTarget: ProjectEditorTarget?
    @State private var openError: String?
    @State private var isOpeningFolder = false

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
        List(selection: $selection) {
            section("Active", active)
            section("Completed", completed)
            section("Archived", archived)
        }
        .listStyle(.sidebar)
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
            do {
                try GitHubCLI.validateGitDirectory(directory)
                let repository = try await GitHubCLI.repository(at: directory)
                let project = BoardMutations.createProject(
                    forRepository: repository,
                    at: directory,
                    in: context,
                    existing: projects
                )
                selection = project.uuid
                showIssues()
            } catch {
                openError = error.localizedDescription
            }
        }
    }

    private func showIssues() {
        NotificationCenter.default.post(
            name: .boardViewModeRequested,
            object: nil,
            userInfo: ["mode": BoardViewMode.issues.rawValue]
        )
    }

    @ViewBuilder
    private func section(_ title: String, _ group: [Project]) -> some View {
        if !group.isEmpty {
            Section(title) {
                ForEach(group, id: \.uuid) { project in
                    ProjectRow(project: project)
                        .tag(project.uuid)
                        .contextMenu {
                            Button("Edit…") { editorTarget = .edit(project) }
                            Button("Duplicate") {
                                BoardMutations.duplicate(project, in: context, existing: projects)
                            }
                            Divider()
                            statusMenu(for: project)
                            Divider()
                            Button("Delete", role: .destructive) { delete(project) }
                        }
                }
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
