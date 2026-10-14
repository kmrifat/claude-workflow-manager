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
    @State private var selectedItemID: UUID?
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

    /// Owned by the app, not per-project: a board that is not on screen still
    /// has to reach `.taskboard/tasks.json`, and a phone can change one at any
    /// time. The card windows share it.
    @Environment(WorkflowSyncCoordinator.self) private var syncCoordinator

    /// Held strongly: `BoardServer.handler` is weak, so nothing else keeps the
    /// service alive and the phone would connect to a server that answers
    /// nothing.
    @State private var boardService: BoardService?

    /// Owned by the app: the server must keep answering while any project — or
    /// none — is on screen, and the card windows ask whether it is on.
    @Environment(MCPServer.self) private var mcpServer
    @State private var tailnet = TailnetAccess.shared

    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow

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
            // A selection only means something on the board it belongs to.
            if let selectedItemID,
               selectedProject?.allItems.contains(where: { $0.uuid == selectedItemID }) != true {
                self.selectedItemID = nil
            }
            filter = BoardFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helpRequested)) { _ in
            showsHelp = true
        }
        .sheet(isPresented: $showsHelp) {
            HelpGuideView()
        }
        .environment(tailnet)
        .task {
            syncCoordinator.start(context: context)

            // Same single publisher as the phone's edits: the coordinator
            // writes `tasks.json` for syncing projects and tells phones.
            mcpServer.tools.didMutate = { syncCoordinator.boardChanged($0) }
            mcpServer.attach(context: context)

            tailnet.onChange = { applyRemote() }
            CloudflareTunnel.shared.onChange = { applyRemote() }
            tailnet.startMonitoring()
            applyRemote()

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
        // Phone Access and the MCP server are started and stopped elsewhere —
        // the sharing sheet, Settings — and the tunnel has to follow.
        .onChange(of: boardServer.state) { _, _ in applyRemote() }
        .onChange(of: mcpServer.isEnabled) { _, _ in applyRemote() }
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
                    selectedItemID: $selectedItemID,
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
    /// Makes what is listening match the Remote settings, for whichever route
    /// is chosen. Called whenever any input changes — a switch, Tailscale's
    /// state, the tunnel's address, a server starting or stopping — and safe to
    /// call when nothing did.
    private func applyRemote() {
        // Tailscale: a second listener on the tailnet address.
        mcpServer.setRemote(tailnet.mcpNode)
        if boardServer.state.isRunning, !boardServer.matchesTailnet(tailnet.phoneNode) {
            boardServer.stop()
            boardServer.startPhoneAccess(tailnet: tailnet.phoneNode)
        }

        // Cloudflare: one tunnel to the gateway, which serves whichever of the
        // two is switched on and running. Nothing runs for a server that is off.
        let tunnel = CloudflareTunnel.shared
        let carriesMCP = tailnet.usesCloudflare && tailnet.exposesMCP && mcpServer.isEnabled
        let carriesPhone = tailnet.usesCloudflare && tailnet.exposesPhone && boardServer.state.isRunning
        if carriesMCP || carriesPhone {
            TunnelGateway.shared.start()
            tunnel.start()
        } else {
            tunnel.stop()
            TunnelGateway.shared.stop()
        }

        let address = tunnel.state.url
        mcpServer.setTunnel(host: carriesMCP ? address?.host() : nil)
        if carriesPhone {
            boardServer.startRelay()
            boardServer.relayURL = address?.absoluteString
        } else {
            boardServer.stopRelay()
            boardServer.relayURL = nil
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
        // `-OpenCard <title>` opens that card's window; `-ShowCard <title>`
        // selects it on the board with its popover showing (see `BoardView`).
        if let title = arguments.string(forKey: "OpenCard"),
           let item = projects.flatMap(\.allItems).first(where: { $0.title == title }) {
            openWindow(id: CardWindow.sceneID, value: item.uuid)
        }
        if let title = arguments.string(forKey: "ShowCard"),
           let item = selectedProject?.allItems.first(where: { $0.title == title }) {
            selectedItemID = item.uuid
        }
        #endif
    }

    private func openProject(_ project: Project) {
        destination = .project(project.uuid)
        viewMode = .board
    }

    /// From the Overview and the queues, which list cards from every project:
    /// the card's own window, so the list stays where it is behind it.
    private func openCard(_ item: WorkItem) {
        openWindow(id: CardWindow.sceneID, value: item.uuid)
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
