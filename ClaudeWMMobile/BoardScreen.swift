//
//  BoardScreen.swift
//  ClaudeWMMobile
//
//  The board itself (M02).
//
//  Columns are a pager with a row of chips above it rather than the Mac's
//  side-by-side lanes: a phone is too narrow for two columns and far too
//  narrow for five, and a pinched-down kanban is worse than one column you can
//  swipe between. The chips say what the other columns hold without visiting
//  them.
//

import SwiftUI
import ClaudeWMWire

struct BoardScreen: View {
    let connection: BoardConnection
    let navigation: PhoneNavigation
    let paired: PairedMac?
    let reconnect: () -> Void

    @State private var columnID: String?
    @State private var addingCard = false

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(connection: connection, paired: paired) }
        }
        .sheet(isPresented: $addingCard) {
            if let snapshot = connection.snapshot {
                NewCardScreen(projectID: snapshot.project.id, projectName: snapshot.project.name,
                              columns: snapshot.columns, columnID: columnID, connection: connection)
            }
        }
        .onChange(of: connection.snapshot?.project.id) { _, _ in
            columnID = defaultColumn
        }
        .onAppear { if columnID == nil { columnID = defaultColumn } }
    }

    /// The first column with work in progress, else the first: what you most
    /// likely came to look at.
    private var defaultColumn: String? {
        guard let columns = connection.snapshot?.columns else { return nil }
        return (columns.first { $0.role == .inProgress && !$0.cards.isEmpty } ?? columns.first)?.id
    }

    // MARK: - Pieces

    @ViewBuilder
    private var content: some View {
        if let snapshot = connection.snapshot, !snapshot.columns.isEmpty {
            VStack(spacing: 0) {
                ColumnChips(columns: snapshot.columns, selection: $columnID)
                TabView(selection: Binding(get: { columnID ?? snapshot.columns[0].id }, set: { columnID = $0 })) {
                    ForEach(snapshot.columns, id: \.id) { column in
                        ColumnList(column: column, snapshot: snapshot, connection: connection, navigation: navigation)
                            .tag(column.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .overlay(alignment: .bottomTrailing) {
                Button { addingCard = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.tint))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(20)
                .accessibilityLabel("New Card")
            }
        } else if connection.selectedProjectID == nil, connection.state.isConnected {
            ContentUnavailableView("Choose a Board", systemImage: "square.stack.3d.up",
                                   description: Text("Pick a project on Home, or from the menu above."))
        } else if connection.state.isConnected {
            ProgressView("Loading board…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Unreachable(paired: paired, retry: reconnect)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(connection.projects.filter { $0.isArchived != true }, id: \.id) { project in
                    Button {
                        connection.select(projectID: project.id)
                    } label: {
                        if project.id == connection.selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(connection.snapshot?.project.name ?? "Board").font(.headline)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                    if let slug = connection.snapshot?.project.repoSlug {
                        Text(slug).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let snapshot = connection.snapshot {
                    Button {
                        connection.requestSnapshot(projectID: snapshot.project.id, force: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

// MARK: - Column chips

private struct ColumnChips: View {
    let columns: [WireColumn]
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(columns, id: \.id) { column in
                        let selected = column.id == selection
                        Button {
                            withAnimation { selection = column.id }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Palette.column(column.role)).frame(width: 6, height: 6)
                                Text(column.name).font(.subheadline.weight(selected ? .semibold : .regular))
                                Text(countText(column))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(column.isOverWIP ? .orange : .secondary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Palette.column(column.role).opacity(0.18)
                                                                : Color(.tertiarySystemFill)))
                            .overlay(Capsule().strokeBorder(selected ? Palette.column(column.role).opacity(0.5) : .clear))
                        }
                        .buttonStyle(.plain)
                        .id(column.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func countText(_ column: WireColumn) -> String {
        if let limit = column.wipLimit { return "\(column.cards.count)/\(limit)" }
        return "\(column.cards.count)"
    }
}

extension WireColumn {
    var isOverWIP: Bool {
        guard let wipLimit else { return false }
        return cards.count > wipLimit
    }
}

// MARK: - Column

private struct ColumnList: View {
    let column: WireColumn
    let snapshot: BoardSnapshot
    let connection: BoardConnection
    let navigation: PhoneNavigation

    var body: some View {
        List {
            if column.cards.isEmpty {
                Text("Nothing in \(column.name).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(column.cards) { card in
                CardTile(card: card, blocked: card.isBlocked(in: snapshot.cardsByID))
                    .contentShape(Rectangle())
                    .onTapGesture { navigation.open(card.id, in: snapshot.project.id) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            connection.mutate(.deleteCard(cardID: card.id))
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            connection.mutate(.setRequested(cardID: card.id, requested: !card.requested))
                        } label: {
                            Label(card.requested ? "Take Back" : "Send to Claude", systemImage: "sparkles")
                        }
                        .tint(Palette.claude)
                    }
                    .swipeActions(edge: .leading) {
                        ForEach(moveTargets, id: \.id) { target in
                            Button {
                                connection.mutate(.moveCard(cardID: card.id, toColumnID: target.id, index: 0))
                            } label: {
                                Label(target.name, systemImage: isBefore(target) ? "arrow.left" : "arrow.right")
                            }
                            .tint(Palette.column(target.role))
                        }
                    }
                    .contextMenu {
                        Menu("Move to") {
                            ForEach(snapshot.columns.filter { $0.id != column.id }, id: \.id) { target in
                                Button(target.name) {
                                    connection.mutate(.moveCard(cardID: card.id, toColumnID: target.id, index: 0))
                                }
                            }
                        }
                        Button(card.requested ? "Take Back from Claude" : "Send to Claude") {
                            connection.mutate(.setRequested(cardID: card.id, requested: !card.requested))
                        }
                        Button("Delete", role: .destructive) { connection.mutate(.deleteCard(cardID: card.id)) }
                    }
            }
            Text("Swipe a card to move it, send it to Claude, or delete it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.bottom, 70)
        }
        .listStyle(.plain)
        .refreshable { connection.requestSnapshot(projectID: snapshot.project.id, force: true) }
    }

    /// Only adjacent columns, and never this one. A full column list on a
    /// swipe is a row of five buttons where four are wrong; the long-press
    /// menu has the rest.
    private var moveTargets: [WireColumn] {
        guard let index = snapshot.columns.firstIndex(where: { $0.id == column.id }) else { return [] }
        return [index - 1, index + 1]
            .filter { snapshot.columns.indices.contains($0) }
            .map { snapshot.columns[$0] }
    }

    private func isBefore(_ target: WireColumn) -> Bool {
        let ids = snapshot.columns.map(\.id)
        return (ids.firstIndex(of: target.id) ?? 0) < (ids.firstIndex(of: column.id) ?? 0)
    }
}

// MARK: - Card

/// A card as the Mac's board draws it: issue and priority, title, Claude's
/// callout while it works, and a footer of what is on it.
struct CardTile: View {
    let card: WireCard
    let blocked: Bool

    private var working: Bool { card.agentState?.isActive == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.githubIssue != nil || card.priority >= .high {
                HStack {
                    if let issue = card.githubIssue {
                        Text("#\(issue)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if card.priority >= .high {
                        Text(card.priority.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(Palette.priority(card.priority))
                            .background(Capsule().fill(Palette.priority(card.priority).opacity(0.16)))
                    }
                }
            }

            Text(card.title.isEmpty ? "Untitled" : card.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(card.isDone ? .secondary : .primary)
                .strikethrough(card.isDone)
                .frame(maxWidth: .infinity, alignment: .leading)

            if working, let state = card.agentState {
                ClaudeCallout(state: state, detail: card.agentDetail)
            }

            footer
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(working ? Palette.claude.opacity(0.6) : Color(.separator).opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var footer: some View {
        let hasFooter = card.dueDate != nil || card.subtaskCount > 0 || card.imageCount > 0 || card.branch != nil
            || blocked || card.owner?.isEmpty == false || (card.requested && !working) || card.prURL != nil
        if hasFooter {
            HStack(spacing: 10) {
                if blocked {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
                if let due = card.dueDate {
                    Label(due.shortDay, systemImage: "calendar")
                        .foregroundStyle(due < Calendar.current.startOfDay(for: .now) && !card.isDone ? .red : .secondary)
                }
                if card.subtaskCount > 0 {
                    Label("\(card.subtasksDone)/\(card.subtaskCount)", systemImage: "checklist")
                }
                if card.imageCount > 0 {
                    Label("\(card.imageCount)", systemImage: "photo")
                }
                if let branch = card.branch {
                    Text(branch).font(.caption.monospaced()).lineLimit(1)
                }
                if card.prURL != nil {
                    Image(systemName: "arrow.triangle.pull")
                }
                if card.requested && !working {
                    Image(systemName: "sparkles").foregroundStyle(Palette.claude)
                }
                Spacer(minLength: 0)
                if let owner = card.owner, !owner.isEmpty {
                    Initials(name: owner)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(TightLabel())
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Connection state

/// What is wrong, if anything: a refusal from the Mac, a dropped connection,
/// or an edit still on its way.
struct ConnectionBanner: View {
    let connection: BoardConnection
    let paired: PairedMac?

    var body: some View {
        if let failure = connection.lastFailure {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                Text(failure).font(.footnote)
                Spacer()
                Button("OK") { connection.dismissFailure() }.font(.footnote)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.orange.opacity(0.2))
        } else if case .disconnected = connection.state {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reconnecting to \(paired?.displayName ?? "your Mac")…").font(.footnote)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thinMaterial)
        } else if connection.hasPendingEdits {
            // The board stays usable while an edit is in flight; this only
            // stops someone assuming a stalled edit landed.
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Saving…").font(.footnote)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }
}

struct Unreachable: View {
    let paired: PairedMac?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can’t reach your Mac", systemImage: "wifi.exclamationmark")
        } description: {
            // Named causes, in the order they actually happen. "Check your
            // connection" would be useless here: the usual answer is that the
            // Mac is asleep.
            Text("""
                Make sure \(paired?.displayName ?? "your Mac") is awake and has Phone Access \
                turned on — and, away from this Wi-Fi, that it has Access from Anywhere on.
                """)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
