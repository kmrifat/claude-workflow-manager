//
//  BoardScreen.swift
//  ClaudeWMMobile
//
//  The board itself.
//
//  Columns are a horizontal pager rather than the Mac's side-by-side lanes: a
//  phone is too narrow for two columns and far too narrow for five, and a
//  pinched-down kanban is worse than one column you can swipe between.
//

import SwiftUI
import ClaudeWMWire

struct BoardScreen: View {
    let connection: BoardConnection
    let browser: BoardBrowser
    @Binding var paired: PairedMac?

    @AppStorage("cardMoveNotificationsEnabled") private var notifyOnMoves = true
    @State private var columnIndex = 0
    @State private var editingCard: WireCard?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(connection.snapshot?.project.name ?? paired?.macName ?? "Claude WM")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) { statusBar }
        }
        .task(id: paired?.service) { connect() }
        .onChange(of: PushRegistration.shared.token) { _, _ in
            // Apple answers asynchronously, usually after the socket is already
            // up, so the token is sent when it arrives rather than at connect.
            connection.sendPushTokenIfAvailable()
        }
        .onChange(of: browser.found.map(\.name)) { _, _ in
            // The Mac appeared on the network — possibly for the first time,
            // possibly after waking. Either way it is now reachable.
            if !connection.state.isConnected { connect() }
        }
        .sheet(item: $editingCard) { card in
            CardDetailSheet(card: card, connection: connection)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var content: some View {
        if let snapshot = connection.snapshot, !snapshot.columns.isEmpty {
            TabView(selection: $columnIndex) {
                ForEach(Array(snapshot.columns.enumerated()), id: \.element.id) { index, column in
                    ColumnView(
                        column: column,
                        snapshot: snapshot,
                        connection: connection,
                        onTap: { editingCard = $0 }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        } else if connection.state.isConnected {
            ProgressView("Loading board…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unreachable
        }
    }

    private var unreachable: some View {
        ContentUnavailableView {
            Label("Can’t reach your Mac", systemImage: "wifi.exclamationmark")
        } description: {
            // Named causes, in the order they actually happen. "Check your
            // connection" would be useless here: the usual answer is that the
            // Mac is asleep.
            Text("""
                Make sure \(paired?.macName ?? "your Mac") is awake, on this Wi-Fi network, \
                and has Phone Access turned on.
                """)
        } actions: {
            Button("Try Again") { connect() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
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
                Text("Reconnecting to \(paired?.macName ?? "your Mac")…").font(.footnote)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if connection.projects.count > 1 {
                Menu {
                    ForEach(connection.projects, id: \.id) { project in
                        Button(project.name) { connection.select(projectID: project.id) }
                    }
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let snapshot = connection.snapshot {
                    Button("Refresh") { connection.requestSnapshot(projectID: snapshot.project.id) }
                }
                Divider()
                Section {
                    Toggle("Notify About Card Moves", isOn: $notifyOnMoves)
                    if notifyOnMoves {
                        // iOS suspends the app and drops the socket shortly
                        // after it leaves the screen, so this is a real limit
                        // rather than a caveat — better said than discovered.
                        Text("Only while Claude WM is open or recently used.")
                    }
                }
                Divider()
                Button("Forget This Mac", role: .destructive) {
                    connection.disconnect()
                    PairedMacStore.forget()
                    paired = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func connect() {
        guard let paired else { return }
        // By Bonjour name, never a remembered address — see `BoardBrowser`.
        guard let endpoint = browser.endpoint(named: paired.service) else { return }
        connection.connect(to: endpoint, key: paired.key)
    }
}

// MARK: - Column

private struct ColumnView: View {
    let column: WireColumn
    let snapshot: BoardSnapshot
    let connection: BoardConnection
    let onTap: (WireCard) -> Void

    @State private var newCardTitle = ""

    var body: some View {
        List {
            Section {
                if column.cards.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary)
                }
                ForEach(column.cards) { card in
                    CardRow(card: card, blocked: card.isBlocked(in: snapshot.cardsByID))
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(card) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                connection.mutate(.deleteCard(cardID: card.id))
                            }
                        }
                        .swipeActions(edge: .leading) {
                            ForEach(moveTargets, id: \.id) { target in
                                Button(target.name) {
                                    connection.mutate(.moveCard(
                                        cardID: card.id, toColumnID: target.id, index: 0
                                    ))
                                }
                            }
                        }
                }
            } header: {
                HStack {
                    Text(column.name)
                    Spacer()
                    Text("\(column.cards.count)")
                        .foregroundStyle(column.isOverWIP ? .orange : .secondary)
                }
            }

            Section {
                HStack {
                    TextField("Add a card", text: $newCardTitle)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newCardTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Only adjacent columns, and never this one. A full column list on a phone
    /// is a menu of five where four are wrong.
    private var moveTargets: [WireColumn] {
        guard let index = snapshot.columns.firstIndex(where: { $0.id == column.id }) else { return [] }
        return [index - 1, index + 1]
            .filter { snapshot.columns.indices.contains($0) }
            .map { snapshot.columns[$0] }
    }

    private func add() {
        let title = newCardTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        connection.mutate(.createCard(columnID: column.id, title: title, details: ""))
        newCardTitle = ""
    }
}

private extension WireColumn {
    var isOverWIP: Bool {
        guard let wipLimit else { return false }
        return cards.count > wipLimit
    }
}

// MARK: - Card

private struct CardRow: View {
    let card: WireCard
    let blocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if card.priority != .normal {
                    Image(systemName: priorityIcon)
                        .foregroundStyle(priorityColour)
                        .font(.caption)
                }
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .strikethrough(card.isDone)
                    .foregroundStyle(card.isDone ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                if blocked {
                    Label("Blocked", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
                if card.requested {
                    Label("Sent to Claude", systemImage: "sparkles")
                        .foregroundStyle(.purple)
                }
                if let issue = card.githubIssue {
                    Label("#\(issue)", systemImage: "smallcircle.filled.circle")
                }
                if card.subtaskCount > 0 {
                    Label("\(card.subtasksDone)/\(card.subtaskCount)", systemImage: "checklist")
                }
                if card.prURL != nil {
                    Image(systemName: "arrow.triangle.pull")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var priorityIcon: String {
        switch card.priority {
        case .urgent: "exclamationmark.2"
        case .high:   "exclamationmark"
        case .low:    "arrow.down"
        case .normal: "minus"
        }
    }

    private var priorityColour: Color {
        switch card.priority {
        case .urgent: .red
        case .high:   .orange
        case .low:    .secondary
        case .normal: .secondary
        }
    }
}

// MARK: - Detail

private struct CardDetailSheet: View {
    let card: WireCard
    let connection: BoardConnection
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var details: String

    init(card: WireCard, connection: BoardConnection) {
        self.card = card
        self.connection = connection
        _title = State(initialValue: card.title)
        _details = State(initialValue: card.details)
    }

    private var blocked: Bool {
        guard let snapshot = connection.snapshot else { return false }
        return card.isBlocked(in: snapshot.cardsByID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                }
                Section("Notes") {
                    TextEditor(text: $details).frame(minHeight: 140)
                }
                Section("Priority") {
                    Picker("Priority", selection: Binding(
                        get: { card.priority },
                        set: { connection.mutate(.setPriority(cardID: card.id, priority: $0)) }
                    )) {
                        ForEach(WirePriority.allCases, id: \.self) { priority in
                            Text(priority.rawValue.capitalized).tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    // Disabled for the same reason the Mac disables it: do not
                    // hand work to an agent that cannot start. The Mac refuses
                    // it server-side too — this is the explanation, not the rule.
                    Button(card.requested ? "Cancel Request" : "Send to Claude") {
                        connection.mutate(.setRequested(cardID: card.id, requested: !card.requested))
                        dismiss()
                    }
                    .disabled(blocked && !card.requested)
                } footer: {
                    if blocked {
                        Text("This card is blocked by unfinished work.")
                    }
                }
                if let prURL = card.prURL, let url = URL(string: prURL) {
                    Section { Link("Open pull request", destination: url) }
                }
            }
            .navigationTitle("Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
        }
    }

    private func save() {
        // Only what actually changed. Sending both every time would produce two
        // events and two board rewrites for a one-character edit.
        if title != card.title { connection.mutate(.setTitle(cardID: card.id, title: title)) }
        if details != card.details { connection.mutate(.setDetails(cardID: card.id, details: details)) }
        dismiss()
    }
}
