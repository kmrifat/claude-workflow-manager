//
//  HomeScreen.swift
//  ClaudeWMMobile
//
//  Home (M01): what needs you, what Claude is doing right now, and every
//  board, grouped by workspace as the Mac's sidebar groups them.
//
//  The smart lists are the Mac's own (`WireOverview`, built from `CardQueue`),
//  so a count here never differs from the sidebar's.
//

import SwiftUI
import ClaudeWMWire

struct HomeScreen: View {
    let connection: BoardConnection
    let navigation: PhoneNavigation
    @Binding var paired: PairedMac?
    let browser: BoardBrowser
    let reconnect: () -> Void

    @State private var showsMac = false

    var body: some View {
        NavigationStack {
            Group {
                if !connection.state.isConnected && connection.projects.isEmpty {
                    Unreachable(paired: paired, retry: reconnect)
                } else {
                    content
                }
            }
            .navigationTitle("Pitwall")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsMac = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Your Mac")
                }
            }
            .navigationDestination(for: Queue.self) { queue in
                QueueScreen(queue: queue, connection: connection, navigation: navigation)
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(connection: connection, paired: paired) }
        }
        .sheet(isPresented: $showsMac) {
            MacScreen(connection: connection, browser: browser, paired: $paired)
        }
    }

    private var overview: WireOverview { connection.overview ?? WireOverview() }

    private var content: some View {
        List {
            Section {
                RouteChip(connection: connection, paired: paired)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Queue.allCases) { queue in
                    NavigationLink(value: queue) {
                        HStack(spacing: 12) {
                            IconTile(symbol: queue.symbol, colour: queue.colour)
                            Text(queue.title)
                            Spacer()
                            Text("\(queue.items(in: overview).count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if !overview.agents.isEmpty {
                Section("Claude Right Now") {
                    ForEach(overview.agents) { item in
                        Button { navigation.open(item.cardID, in: item.projectID) } label: {
                            AgentRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Palette.claude.opacity(0.10))
                    }
                }
            }

            ForEach(workspaces, id: \.name) { workspace in
                Section(workspace.name) {
                    ForEach(workspace.projects, id: \.id) { project in
                        Button {
                            connection.select(projectID: project.id)
                            navigation.tab = .board
                        } label: {
                            ProjectRow(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            connection.requestOverview()
            connection.send(.listProjects)
        }
    }

    /// Projects by their top folder, pinned first; archived boards left out.
    private var workspaces: [(name: String, projects: [WireProjectRef])] {
        var order: [String] = []
        var groups: [String: [WireProjectRef]] = [:]
        for project in connection.projects where project.isArchived != true {
            let name = project.path?.first ?? "Projects"
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(project)
        }
        return order.map { name in
            (name, groups[name]!.sorted { ($0.isPinned == true ? 0 : 1) < ($1.isPinned == true ? 0 : 1) })
        }
    }
}

// MARK: - Rows

/// "● Rifat's MacBook Pro · Local network"
struct RouteChip: View {
    let connection: BoardConnection
    let paired: PairedMac?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connection.state.isConnected ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(paired?.displayName ?? "Your Mac").font(.footnote.weight(.medium))
            Text("·").foregroundStyle(.tertiary)
            Text(connection.state.isConnected ? connection.route.title : "Reconnecting…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

extension BoardConnection.Route {
    var title: String {
        switch self {
        case .local:   "Local network"
        case .tailnet: "Tailscale"
        case .tunnel:  "Cloudflare Tunnel"
        }
    }
}

struct IconTile: View {
    var symbol: String
    var colour: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(colour))
    }
}

private struct AgentRow: View {
    let item: WireQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(Palette.claude).frame(width: 6, height: 6)
                Text(item.columnName).font(.caption.weight(.semibold)).foregroundStyle(Palette.claude)
                Spacer()
                Text(item.projectName).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.title).font(.body.weight(.semibold))
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct ProjectRow: View {
    let project: WireProjectRef

    var body: some View {
        HStack(spacing: 12) {
            ProjectIcon(project: project)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                if let path = project.path, path.count > 1 {
                    Text(path.dropFirst().joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let slug = project.repoSlug {
                    Text(slug).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let working = project.agentsWorking, working > 0 {
                Circle().fill(Palette.claude).frame(width: 7, height: 7)
                    .accessibilityLabel("\(working) with Claude")
            }
            if let total = project.totalCount, total > 0 {
                Text("\(project.doneCount ?? 0)/\(total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The project's own symbol and colour from the Mac, or its initial when the
/// symbol is one iOS does not have.
private struct ProjectIcon: View {
    let project: WireProjectRef

    var body: some View {
        let colour = Palette.accent(project.accent)
        if let symbol = project.symbol, UIImage(systemName: symbol) != nil {
            IconTile(symbol: symbol, colour: colour)
        } else {
            Text(String(project.name.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(colour))
        }
    }
}

// MARK: - Smart lists

enum Queue: String, CaseIterable, Identifiable, Hashable {
    case agents, review, overdue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents:  "Agents working"
        case .review:  "Needs review"
        case .overdue: "Overdue"
        }
    }

    var symbol: String {
        switch self {
        case .agents:  "sparkles"
        case .review:  "eye"
        case .overdue: "calendar.badge.exclamationmark"
        }
    }

    var colour: Color {
        switch self {
        case .agents:  Palette.claude
        case .review:  .orange
        case .overdue: .red
        }
    }

    func items(in overview: WireOverview) -> [WireQueueItem] {
        switch self {
        case .agents:  overview.agents
        case .review:  overview.review
        case .overdue: overview.overdue
        }
    }
}

struct QueueScreen: View {
    let queue: Queue
    let connection: BoardConnection
    let navigation: PhoneNavigation

    var body: some View {
        let items = queue.items(in: connection.overview ?? WireOverview())
        List {
            if items.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button { navigation.open(item.cardID, in: item.projectID) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.body.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(item.projectName)
                            Text("·").foregroundStyle(.tertiary)
                            Text(item.columnName)
                            if let due = item.dueDate {
                                Text("·").foregroundStyle(.tertiary)
                                Text("Due \(due.shortDay)").foregroundStyle(queue == .overdue ? .red : .secondary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(queue.title)
        .refreshable { connection.requestOverview() }
    }
}
