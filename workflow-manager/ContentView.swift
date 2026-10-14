//
//  ContentView.swift
//  workflow-manager
//
//  Created by rifat on 31/7/26.
//

import SwiftUI
import SwiftData
import ClaudeWMWire

struct ContentView: View {
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    /// Selection is a `UUID`, never a model object: a `List(selection:)` bound
    /// to a deleted `@Model` can crash on the next render, whereas a stale
    /// UUID simply stops resolving.
    @State private var destination: AppDestination = .overview
    @State private var viewMode: BoardViewMode = .board
    @State private var inspectedItemID: UUID?
    @State private var filter = BoardFilter()
    /// Which half of the window has the keyboard; see `FocusPane`.
    @FocusState private var focusedPane: FocusPane?
    /// Both live here, above the per-project detail view, so their state — open
    /// files, and running terminals — survives switching projects and tabs.
    @State private var filesStore = FilesStateStore()
    @State private var terminalStore = TerminalStateStore()
    @State private var showsHelp = false
    @State private var showsPhoneAccess = false

    /// Owned here rather than by the sharing sheet, for the same reason terminal
    /// sessions are owned by `ProjectDetailView`: closing the window that
    /// configured it must not drop the connections.
    @State private var boardServer = BoardServer()

    /// App-level, not per-project: a board that is not on screen still has to
    /// reach `.taskboard/tasks.json`, and a phone can change one at any time.
    @State private var syncCoordinator = WorkflowSyncCoordinator()

    /// Held strongly: `BoardServer.handler` is weak, so nothing else keeps the
    /// service alive and the phone would connect to a server that answers
    /// nothing.
    @State private var boardService: BoardService?

    /// App-level for the same reason as `boardServer`: the server must keep
    /// answering while any project — or none — is on screen.
    @State private var mcpServer = MCPServer()
    @State private var tailnet = TailnetAccess.shared

    @Environment(\.modelContext) private var context

    private var selectedProject: Project? {
        guard let id = destination.projectID else { return nil }
        return projects.first { $0.uuid == id }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                destination: $destination,
                viewMode: $viewMode,
                focus: $focusedPane,
                isSharing: boardServer.state.isRunning,
                isMCPRunning: mcpServer.state.isRunning
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .environment(filesStore)
        .environment(terminalStore)
        // The issue cache has no relationship to cascade from, on purpose, so
        // rows for deleted projects are swept once at launch.
        .task {
            IssueCache.prune(keeping: Set(projects.map(\.uuid)), in: context)
            applyLaunchArguments()
        }
        .onReceive(NotificationCenter.default.publisher(for: .boardViewModeRequested)) { note in
            guard let raw = note.userInfo?["mode"] as? String,
                  let mode = BoardViewMode(rawValue: raw) else { return }
            viewMode = mode
        }
        .onChange(of: destination) { _, _ in
            // Overview and the queues open a card by setting both at once, so
            // keep the card if it belongs to the project now on screen.
            if let inspectedItemID,
               selectedProject?.allItems.contains(where: { $0.uuid == inspectedItemID }) != true {
                self.inspectedItemID = nil
            }
            filter = BoardFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helpRequested)) { _ in
            showsHelp = true
        }
        .sheet(isPresented: $showsHelp) {
            HelpGuideView()
        }
        .environment(syncCoordinator)
        .environment(mcpServer)
        .environment(tailnet)
        .task {
            syncCoordinator.start(context: context)

            // Same single publisher as the phone's edits: the coordinator
            // writes `tasks.json` for syncing projects and tells phones.
            mcpServer.tools.didMutate = { syncCoordinator.boardChanged($0) }
            mcpServer.attach(context: context)

            tailnet.onChange = { applyTailnet() }
            tailnet.startMonitoring()

            let service = BoardService(context: context)
            service.didMutate = { syncCoordinator.boardChanged($0) }
            // The same terminal sessions the Mac shows, so a phone attaches to
            // the dev server already running rather than starting a second one.
            service.attachRepositoryAccess(terminals: terminalStore)
            boardServer.handler = service
            boardService = service

            // One publisher for "this board changed", covering edits from the
            // Mac, from a phone, and from an agent's merge alike. Phones compare
            // the revision against their own and ask for a snapshot only if it
            // differs, so an idle phone costs one integer per change.
            syncCoordinator.onBoardChanged = { project in
                boardServer.broadcast(.event(
                    projectID: project.uuid.uuidString,
                    revision: BoardSnapshotBuilder.revision(of: project)
                ))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .phoneAccessRequested)) { _ in
            showsPhoneAccess = true
        }
        .sheet(isPresented: $showsPhoneAccess) {
            BoardSharingView(server: boardServer)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .overview:
            OverviewView(open: openCard, openProject: openProject)
        case .queue(let queue):
            CardQueueView(queue: queue, open: openCard)
        case .settings:
            SettingsView(server: mcpServer, boardServer: boardServer, tailnet: tailnet)
        case .project:
            if let selectedProject {
                ProjectDetailView(
                    project: selectedProject,
                    viewMode: $viewMode,
                    filter: $filter,
                    inspectedItemID: $inspectedItemID,
                    focus: $focusedPane
                )
                // Reset per-project view state when switching projects.
                .id(selectedProject.uuid)
            } else {
                ContentUnavailableView(
                    "Project Not Found",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("It may have been deleted. Pick another project in the sidebar.")
                )
            }
        }
    }

    /// Puts each server where remote access says it should be. Phone Access
    /// has to restart to move between its LAN port and its fixed tailnet one;
    /// the MCP server only adds or drops its second listener.
    private func applyTailnet() {
        mcpServer.setRemote(tailnet.mcpNode)
        if boardServer.state.isRunning, !boardServer.matchesTailnet(tailnet.phoneNode) {
            boardServer.stop()
            boardServer.startPhoneAccess(tailnet: tailnet.phoneNode)
        }
    }

    /// Debug only: `-OpenProject <name>` and `-ViewMode <mode>` land on a given
    /// screen at launch, so a build can be checked by screenshot without
    /// clicking through to it.
    private func applyLaunchArguments() {
        #if DEBUG
        let arguments = UserDefaults.standard
        if let name = arguments.string(forKey: "OpenProject"),
           let project = projects.first(where: { $0.name == name }) {
            destination = .project(project.uuid)
        }
        if let raw = arguments.string(forKey: "ViewMode"), let mode = BoardViewMode(rawValue: raw) {
            viewMode = mode
        }
        if let raw = arguments.string(forKey: "OpenQueue"), let queue = CardQueue(rawValue: raw) {
            destination = .queue(queue)
        }
        if arguments.bool(forKey: "OpenSettings") {
            destination = .settings
        }
        if let title = arguments.string(forKey: "InspectCard"),
           let item = selectedProject?.allItems.first(where: { $0.title == title }) {
            inspectedItemID = item.uuid
        }
        #endif
    }

    private func openProject(_ project: Project) {
        destination = .project(project.uuid)
        viewMode = .board
    }

    /// Lands on the card's board with the card open — from the Overview and
    /// the queues, which list cards from every project.
    private func openCard(_ item: WorkItem) {
        guard let project = item.project else { return }
        inspectedItemID = item.uuid
        destination = .project(project.uuid)
        viewMode = .board
    }
}

#if DEBUG
#Preview("Seeded") {
    ContentView()
        .modelContainer(SampleData.container)
        .frame(width: 1200, height: 760)
}

#Preview("Empty") {
    ContentView()
        .modelContainer(AppModelContainer.make(inMemory: true))
        .frame(width: 1000, height: 700)
}
#endif
