//
//  ContentView.swift
//  workflow-manager
//
//  Created by rifat on 31/7/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    /// Selection is a `UUID`, never a model object: a `List(selection:)` bound
    /// to a deleted `@Model` can crash on the next render, whereas a stale
    /// UUID simply stops resolving.
    @State private var selectedProjectID: UUID?
    @State private var viewMode: BoardViewMode = .board
    @State private var inspectedItemID: UUID?
    @State private var filter = BoardFilter()
    /// Both live here, above the per-project detail view, so their state — open
    /// files, and running terminals — survives switching projects and tabs.
    @State private var filesStore = FilesStateStore()
    @State private var terminalStore = TerminalStateStore()
    @State private var showsHelp = false

    @Environment(\.modelContext) private var context

    private var selectedProject: Project? {
        projects.first { $0.uuid == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(selection: $selectedProjectID)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if let selectedProject {
                ProjectDetailView(
                    project: selectedProject,
                    viewMode: $viewMode,
                    filter: $filter,
                    inspectedItemID: $inspectedItemID
                )
                // Reset per-project view state when switching projects.
                .id(selectedProject.uuid)
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Pick a project in the sidebar, or press ⌘N to create one.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(filesStore)
        .environment(terminalStore)
        // The issue cache has no relationship to cascade from, on purpose, so
        // rows for deleted projects are swept once at launch.
        .task {
            IssueCache.prune(keeping: Set(projects.map(\.uuid)), in: context)
        }
        .onReceive(NotificationCenter.default.publisher(for: .boardViewModeRequested)) { note in
            guard let raw = note.userInfo?["mode"] as? String,
                  let mode = BoardViewMode(rawValue: raw) else { return }
            viewMode = mode
        }
        .onChange(of: selectedProjectID) { _, _ in
            inspectedItemID = nil
            filter = BoardFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helpRequested)) { _ in
            showsHelp = true
        }
        .sheet(isPresented: $showsHelp) {
            HelpGuideView()
        }
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
