//
//  GitHubIssuesView.swift
//  workflow-manager
//
//  The GitHub side of the workboard: open issues for the project's linked
//  repository, fetched through `gh`.
//
//  Read-only on purpose. Cards cannot be dragged or edited, because the columns
//  here are derived from GitHub state rather than owned by us — moving one would
//  mean calling GitHub, which is a later step.
//

import SwiftUI
import SwiftData

struct GitHubIssuesView: View {
    @Bindable var project: Project
    /// Only `searchText` applies to issues; the work-item filters are hidden in
    /// this mode by `ProjectDetailView`.
    var searchText: String = ""

    @Environment(\.modelContext) private var context

    @State private var model = GitHubIssuesModel()
    @State private var git = RepositoryStatusModel()
    @State private var claude = ClaudeSessionModel()
    @State private var connectError: String?
    @State private var selectedIssue: GitHubIssue?
    @State private var suggestions: [IssueLinkSuggester.Suggestion] = []
    @State private var showingSuggestions = false
    @State private var addingIssue: GitHubIssue?

    /// One scan per render, shared by every card. Never call this per card.
    private var linkedNumbers: Set<Int> {
        IssueLinking.linkedNumbers(in: project)
    }

    /// How often the board refreshes itself while on screen. Derived from the
    /// cache TTL so there is exactly one number: entering the view refetches
    /// past that age, and the loop then holds the same cadence.
    private static let refreshInterval: Duration = .seconds(IssueCache.ttl)

    private var visibleIssues: [GitHubIssue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.issues }
        return model.issues.filter { $0.matches(query) }
    }

    var body: some View {
        Group {
            if project.hasRepository {
                loadedBoard
            } else {
                notConnected
            }
        }
        .background(.background.secondary)
        .task(id: project.repoPath) {
            await model.loadIfNeeded(for: project, in: context)
            await git.loadIfNeeded(for: project, issues: model.issues)
        }
        .task(id: project.repoPath) {
            // Periodic refresh, cancelled automatically when the view goes away.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .sheet(isPresented: $showingSuggestions) {
            IssueLinkSuggestionsSheet(project: project, suggestions: suggestions)
        }
        .confirmationDialog(
            addingIssue.map { "Add #\($0.number) to which column?" } ?? "",
            isPresented: .init(get: { addingIssue != nil }, set: { if !$0 { addingIssue = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(project.orderedColumns, id: \.uuid) { column in
                Button(column.name) { addToBoard(column: column) }
            }
            Button("Cancel", role: .cancel) { addingIssue = nil }
        }
        .alert(
            "Couldn’t connect the repository",
            isPresented: .init(get: { connectError != nil }, set: { if !$0 { connectError = nil } })
        ) {
            Button("OK", role: .cancel) { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
        .alert(
            "Couldn’t start Claude",
            isPresented: .init(
                get: { claude.errorMessage != nil },
                set: { if !$0 { claude.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { claude.clearError() }
        } message: {
            Text(claude.errorMessage ?? "")
        }
    }

    // MARK: - States

    private var notConnected: some View {
        ContentUnavailableView {
            Label("No Repository Linked", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Choose the folder holding this project’s Git repository to see its open issues.")
        } actions: {
            Button("Choose Repository…") { connect() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var loadedBoard: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // Only when there is nothing to show. A refresh that failed over a
            // populated board reports itself in the header instead.
            if let message = model.errorMessage, model.issues.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Issues", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await refresh() } }
                    Button("Choose a Different Folder…") { connect() }
                }
                .frame(maxHeight: .infinity)
            } else if model.isLoading && model.issues.isEmpty {
                ProgressView("Loading issues…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.issues.isEmpty {
                ContentUnavailableView {
                    Label("No Open Issues", systemImage: "checkmark.circle")
                } description: {
                    Text("\(project.repoSlug ?? "This repository") has no open issues.")
                }
                .frame(maxHeight: .infinity)
            } else if visibleIssues.isEmpty {
                // Distinct from "no open issues" — the repository has work, the
                // search just didn't match any of it.
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                columns
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(project.accent.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.repoSlug ?? "Linked repository")
                    .font(.system(size: 12, weight: .semibold))
                Text(project.repoPath ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if let branch = git.currentBranch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    if git.hasUncommittedChanges {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .help(git.hasUncommittedChanges
                      ? "On \(branch) — uncommitted changes"
                      : "On \(branch) — working tree clean")
            }

            Spacer()

            claudeControl

            if let message = model.refreshError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("Showing cached issues")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.12), in: .capsule)
                .help("The last refresh failed: \(message)")
            }

            if let fetchedAt = model.fetchedAt {
                Text("updated \(fetchedAt, style: .relative) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await refresh() }
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoading)
            .help("Refresh from GitHub")

            Menu {
                Button("Suggest Links from Titles…") { suggestLinks() }
                    .disabled(model.issues.isEmpty)
                Divider()
                Button("Choose a Different Folder…") { connect() }
                if let slug = project.repoSlug,
                   let url = URL(string: "https://github.com/\(slug)/issues") {
                    Link("Open Issues on GitHub", destination: url)
                }
                Divider()
                Button("Unlink Repository", role: .destructive) { disconnect() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Start / status for this repository's Claude Remote Control server.
    ///
    /// Deliberately no log viewer: the Claude app renders the conversation, and
    /// this only reports whether a server is up.
    @ViewBuilder
    private var claudeControl: some View {
        if let session = claude.session {
            Menu {
                if let url = URL(string: "https://claude.ai/code") {
                    Link("Open Claude Code", destination: url)
                }
                Button("Reveal Session Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.logURL])
                }
                Divider()
                Button("Stop Session", role: .destructive) { claude.stop() }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Claude")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Remote Control running in \(session.repository.lastPathComponent) — sessions appear in the Claude app")
        } else {
            Button {
                Task { await claude.start(for: project) }
            } label: {
                if claude.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .buttonStyle(.borderless)
            .disabled(claude.isStarting)
            .help("Start a Claude Code session in this repository")
        }
    }

    private var columns: some View {
        let linked = linkedNumbers
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(IssueLane.allCases) { lane in
                    IssueLaneColumn(
                        lane: lane,
                        issues: lane.issues(from: visibleIssues),
                        accent: project.accent.color,
                        linkedNumbers: linked,
                        accentProject: project,
                        summary: { git.summary(forIssue: $0.number) },
                        selectedIssue: $selectedIssue,
                        linkedTitle: {
                            IssueLinking.linkedItem(forIssue: $0, in: project)?.title
                        },
                        onAddToBoard: { issue, columnID in
                            addToBoard(issue: issue, columnID: columnID)
                            selectedIssue = nil
                        },
                        onQuickAdd: { addingIssue = $0 }
                    )
                    .frame(width: BoardView.columnWidth)
                }
            }
            .padding(20)
            // `.topLeading`, not the default `.center`: the lanes are
            // intrinsic-height, so a full-height frame would park them in the
            // middle of the viewport.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    // MARK: - Actions

    /// Issues first, then git — the branch lookup only runs for issues we have.
    /// Always refetches: the refresh button and the periodic loop both mean
    /// "now", so neither consults the TTL.
    private func refresh() async {
        await model.reload(for: project, in: context)
        await git.reload(for: project, issues: model.issues)
    }

    /// Adds the pending issue to `column` as a linked card.
    ///
    /// Refuses to create a second card for an issue the board already tracks —
    /// the schema allows it, but nothing good comes of two cards fighting over
    /// one issue's status.
    private func addToBoard(column: BoardColumn) {
        defer { addingIssue = nil }
        guard let issue = addingIssue else { return }
        add(issue, to: column)
    }

    private func addToBoard(issue: GitHubIssue, columnID: UUID) {
        guard let column = project.columns.first(where: { $0.uuid == columnID }) else { return }
        add(issue, to: column)
    }

    private func add(_ issue: GitHubIssue, to column: BoardColumn) {
        guard IssueLinking.linkedItem(forIssue: issue.number, in: project) == nil else { return }
        withAnimation(.snappy(duration: 0.2)) {
            IssueLinking.createWorkItem(from: issue, in: column, context: context)
        }
    }

    /// Proposes links for unlinked cards. Nothing is applied here — the sheet
    /// is the confirmation step.
    private func suggestLinks() {
        let claimed = linkedNumbers
        let candidates = project.allItems
            .filter { $0.githubIssueNumber == nil }
            .map { IssueLinkSuggester.Candidate(uuid: $0.uuid, title: $0.title) }

        suggestions = IssueLinkSuggester.suggestions(
            for: candidates,
            issues: model.issues,
            claimedIssueNumbers: claimed
        )
        showingSuggestions = true
    }

    private func connect() {
        Task {
            do {
                try await RepositoryPicker.connect(to: project, startingAt: project.repoDirectory)
                await refresh()
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        IssueCache.remove(for: project, in: context)
        project.repoPath = nil
        project.repoOwner = nil
        project.repoName = nil
        project.repoDefaultBranch = nil
        model.reset()
        git.reset()
    }
}

/// The two lanes worth showing before a real project board exists.
///
/// Assignment is the meaningful split: it is how a run claims an issue, and how
/// two machines avoid picking up the same work. Inventing columns GitHub doesn't
/// have would just be decoration.
private enum IssueLane: String, CaseIterable, Identifiable {
    case unclaimed
    case claimed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unclaimed: "Unclaimed"
        case .claimed:   "Claimed"
        }
    }

    var symbol: String {
        switch self {
        case .unclaimed: "tray"
        case .claimed:   "person.fill.checkmark"
        }
    }

    func issues(from issues: [GitHubIssue]) -> [GitHubIssue] {
        switch self {
        case .unclaimed: issues.filter { !$0.isClaimed }
        case .claimed:   issues.filter(\.isClaimed)
        }
    }
}

private struct IssueLaneColumn: View {
    let lane: IssueLane
    let issues: [GitHubIssue]
    let accent: Color
    let linkedNumbers: Set<Int>
    let accentProject: Project
    let summary: (GitHubIssue) -> GitReader.BranchSummary?
    /// Which issue's popover is open, shared across both lanes so opening one
    /// closes another.
    @Binding var selectedIssue: GitHubIssue?
    let linkedTitle: (Int) -> String?
    let onAddToBoard: (GitHubIssue, UUID) -> Void
    /// The context-menu route, which asks for a column in its own dialog rather
    /// than making the user open the popover first.
    let onQuickAdd: (GitHubIssue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: lane.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(lane.title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(issues.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            cardList
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    private func popoverBinding(for issue: GitHubIssue) -> Binding<Bool> {
        Binding(
            get: { selectedIssue == issue },
            set: { isShown in
                if isShown { selectedIssue = issue }
                else if selectedIssue == issue { selectedIssue = nil }
            }
        )
    }

    /// Scrolls on its own, like `BoardColumnView.cardList`. Without this a lane
    /// taller than the viewport overflows both ends of the horizontal scroll
    /// view with no way to reach it, and the lane box stops filling the height.
    private var cardList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if issues.isEmpty {
                    Text("Nothing here")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(issues) { issue in
                        Button {
                            selectedIssue = selectedIssue == issue ? nil : issue
                        } label: {
                            GitHubIssueCard(
                                issue: issue,
                                accent: accent,
                                branchSummary: summary(issue),
                                trackedLocally: linkedNumbers.contains(issue.number),
                                onAddToBoard: { onQuickAdd(issue) }
                            )
                        }
                        .buttonStyle(.plain)
                        .popover(
                            isPresented: popoverBinding(for: issue),
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .trailing
                        ) {
                            GitHubIssueDetailSheet(
                                issue: issue,
                                repositorySlug: accentProject.repoSlug,
                                accent: accent,
                                branchSummary: summary(issue),
                                linkedItemTitle: linkedTitle(issue.number),
                                columns: accentProject.orderedColumns.map { ($0.uuid, $0.name) },
                                onAddToBoard: { onAddToBoard(issue, $0) },
                                presentation: .popover,
                                onClose: { selectedIssue = nil }
                            )
                        }
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }
}
