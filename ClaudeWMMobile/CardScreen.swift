//
//  CardScreen.swift
//  ClaudeWMMobile
//
//  One card, in full — the phone's version of the Mac's card window
//  (`design/ClaudeWM.fig` › Mobile · iPhone › M03). Like the window it has no
//  Save: each field goes to the Mac as it is set, and the Mac's answer
//  replaces the phone's guess a moment later.
//
//  The notes read as rendered Markdown with their pictures in place; tapping
//  them opens the editor. The box at the bottom leaves a note *for Claude* —
//  it lands in the card's activity as "You", which is where `get_card` hands
//  it to the agent.
//

import SwiftUI
import ClaudeWMWire

struct CardScreen: View {
    let projectID: String
    let cardID: String
    let connection: BoardConnection

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var noteDraft = ""
    @State private var newSubtask = ""
    @State private var editingNotes = false
    @State private var confirmingDelete = false
    @FocusState private var focus: Field?

    private enum Field { case title, subtask, note }

    private var detail: WireCardDetail? { connection.cardDetails[cardID] }

    /// The board's copy, shown until the full card arrives.
    private var card: WireCard? {
        detail?.card ?? connection.snapshot?.cardsByID[cardID]
    }

    private var columns: [WireColumn] {
        guard let snapshot = connection.snapshot, snapshot.project.id == projectID else { return [] }
        return snapshot.columns
    }

    private var column: WireColumn? {
        let id = detail?.columnID ?? columns.first { $0.cards.contains { $0.id == cardID } }?.id
        return columns.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let card {
                    content(card)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // A card opened from Home may be on another board. Its columns
            // come with that board's snapshot, so that board becomes the one
            // shown — which is also where you would look for it next.
            if connection.selectedProjectID != projectID { connection.select(projectID: projectID) }
            connection.open(cardID: cardID, in: projectID)
            title = card?.title ?? ""
        }
        .onDisappear {
            saveTitle()
            connection.closeCard()
        }
        .onChange(of: card?.title) { _, newTitle in
            if focus != .title, let newTitle { title = newTitle }
        }
        .onChange(of: focus) { old, _ in
            if old == .title { saveTitle() }
        }
        .sheet(isPresented: $editingNotes) {
            if let card {
                NotesEditScreen(projectID: projectID, cardID: cardID, original: card.details, connection: connection)
            }
        }
        .confirmationDialog("Delete this card?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Card", role: .destructive) {
                connection.mutate(.deleteCard(cardID: cardID), in: projectID)
                dismiss()
            }
        } message: {
            Text("It is deleted on your Mac too.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
        }
        ToolbarItem(placement: .principal) {
            if let column {
                Menu {
                    ForEach(columns, id: \.id) { target in
                        Button {
                            connection.mutate(.moveCard(cardID: cardID, toColumnID: target.id, index: 0), in: projectID)
                        } label: {
                            if target.id == column.id { Label(target.name, systemImage: "checkmark") } else { Text(target.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Chip(text: column.name, tint: Palette.column(column.role), filled: true, dot: true)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let card {
                    Button {
                        connection.mutate(.setRequested(cardID: cardID, requested: !card.requested), in: projectID)
                    } label: {
                        Label(card.requested ? "Take Back from Claude" : "Send to Claude",
                              systemImage: card.requested ? "arrow.uturn.backward" : "sparkles")
                    }
                    .disabled(isBlocked && !card.requested)
                    if let pr = card.prURL, let url = URL(string: pr) {
                        Link(destination: url) { Label("Open Pull Request", systemImage: "arrow.triangle.pull") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete Card", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private var isBlocked: Bool {
        guard let card, let snapshot = connection.snapshot else { return false }
        return card.isBlocked(in: snapshot.cardsByID)
    }

    // MARK: - Content

    private func content(_ card: WireCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let created = detail?.createdAt, created > .distantPast {
                    Text(created.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Title", text: $title, axis: .vertical)
                    .font(.title.bold())
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }

                CardFieldChips(
                    priority: binding(card.priority) { .setPriority(cardID: cardID, priority: $0) },
                    dueDate: binding(card.dueDate) { .setDueDate(cardID: cardID, dueDate: $0) },
                    owner: binding(card.owner ?? "") { .setOwner(cardID: cardID, owner: $0) },
                    tags: binding(card.tags) { .setTags(cardID: cardID, tags: $0) },
                    issue: card.githubIssue,
                    issueURL: card.githubIssue.flatMap { number in
                        card.githubRepoSlug.flatMap { URL(string: "https://github.com/\($0)/issues/\(number)") }
                    }
                )

                if isBlocked {
                    Label("Blocked by unfinished work", systemImage: "hand.raised.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let detail, detail.agentState != .none {
                    ClaudeCallout(state: detail.agentState,
                                  detail: [card.agentDetail, card.branch.map { "branch \($0)" }]
                                      .compactMap { $0 }.joined(separator: " · "),
                                  since: detail.claimedAt)
                }

                notes(card)

                subtasks

                if let detail, !detail.activity.isEmpty {
                    activity(detail.activity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { composer }
    }

    @ViewBuilder
    private func notes(_ card: WireCard) -> some View {
        Group {
            if card.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add notes — Markdown and photos.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                NotesView(text: card.details, projectID: projectID,
                          attachments: detail?.attachments ?? [], connection: connection)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingNotes = true }
        .padding(.top, 4)
    }

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Subtasks").font(.headline)
                Spacer()
                if let detail, !detail.subtasks.isEmpty {
                    Text("\(detail.subtasks.filter(\.done).count) of \(detail.subtasks.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)

            ForEach(detail?.subtasks ?? []) { subtask in
                HStack(spacing: 10) {
                    Button {
                        connection.mutate(.setSubtask(cardID: cardID, subtaskID: subtask.id, done: !subtask.done),
                                          in: projectID)
                    } label: {
                        Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(subtask.done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    Text(subtask.title)
                        .strikethrough(subtask.done)
                        .foregroundStyle(subtask.done ? .secondary : .primary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .contextMenu {
                    Button("Delete Subtask", role: .destructive) {
                        connection.mutate(.deleteSubtask(cardID: cardID, subtaskID: subtask.id), in: projectID)
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "circle").font(.title3).foregroundStyle(.quaternary)
                TextField("New subtask", text: $newSubtask)
                    .focused($focus, equals: .subtask)
                    .submitLabel(.next)
                    .onSubmit(addSubtask)
            }
            .padding(.vertical, 6)
        }
        .padding(.top, 8)
    }

    private func activity(_ events: [WireActivity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline)
            ForEach(events.prefix(12)) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.actor).font(.footnote.weight(.semibold))
                            .foregroundStyle(event.tool == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.claude))
                        Text(event.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.date, format: .relative(presentation: .named))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let note = event.note {
                        Text(note).font(.callout)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    /// "Note for Claude…"
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Note for Claude…", text: $noteDraft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focus, equals: .note)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
            Button(action: sendNote) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.claude))
            }
            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .accessibilityLabel("Send Note")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    /// A field bound to the Mac: reading shows the card, writing sends the
    /// mutation (only when the value really changed).
    private func binding<Value: Equatable>(_ value: Value, _ mutation: @escaping (Value) -> BoardMutation) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                guard newValue != value else { return }
                connection.mutate(mutation(newValue), in: projectID)
            }
        )
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let card, !trimmed.isEmpty, trimmed != card.title else { return }
        connection.mutate(.setTitle(cardID: cardID, title: trimmed), in: projectID)
    }

    private func addSubtask() {
        let trimmed = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        connection.mutate(.addSubtask(cardID: cardID, title: trimmed), in: projectID)
        newSubtask = ""
        focus = .subtask
    }

    private func sendNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connection.mutate(.addNote(cardID: cardID, note: trimmed), in: projectID)
        noteDraft = ""
        focus = nil
    }
}

// MARK: - Editing the notes

/// The notes in the Markdown editor, pictures drawn in place. Photos go to the
/// Mac as soon as they are chosen; Done saves the text once they have all
/// arrived.
struct NotesEditScreen: View {
    let projectID: String
    let cardID: String
    let original: String
    let connection: BoardConnection

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var controller = NotesEditorController()

    var body: some View {
        NavigationStack {
            NotesEditor(text: $text, placeholder: "Notes. # for a heading, - for a list, [] for a checklist — or add a photo.",
                        controller: controller, images: connection.notesImages(in: projectID))
                .padding(.horizontal, 20)
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            connection.saveDetails(text, cardID: cardID, in: projectID, previous: original)
                            dismiss()
                        }
                        .bold()
                    }
                }
        }
        .imageSources(controller) { picked in
            let id = connection.upload(picked.data, filename: picked.filename, preview: picked.preview,
                                       cardID: cardID, in: projectID)
            controller.insertImageLine(PendingImage.markdown(name: picked.filename, uploadID: id))
        }
        .interactiveDismissDisabled(text != original)
        .onAppear {
            text = original
            DispatchQueue.main.async { controller.focus() }
        }
    }
}
