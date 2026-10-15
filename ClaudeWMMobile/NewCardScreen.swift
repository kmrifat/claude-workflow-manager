//
//  NewCardScreen.swift
//  ClaudeWMMobile
//
//  A new card, written like a note (M04/M05): title, fields as chips, then
//  Markdown notes with photos in them.
//
//  The Mac mints card ids, so Add runs in three steps: create the card, then
//  — once the Mac has said what it is called — set its fields and send its
//  photos, then save the notes with each photo's reference where it was
//  placed. The screen stays up while the photos travel, with their progress,
//  because a card that appears on the board without the screenshot it was
//  about reads as a lost photo.
//

import SwiftUI
import ClaudeWMWire

struct NewCardScreen: View {
    let projectID: String
    let projectName: String
    let columns: [WireColumn]
    let connection: BoardConnection

    @Environment(\.dismiss) private var dismiss
    @State private var columnID: String
    @State private var title = ""
    @State private var notes = ""
    @State private var priority = WirePriority.normal
    @State private var dueDate: Date?
    @State private var owner = ""
    @State private var tags: [String] = []
    /// Photos chosen before the card exists, by the id their line carries.
    @State private var staged: [String: PickedImage] = [:]
    @State private var phase = Phase.editing
    @State private var controller = NotesEditorController()
    @FocusState private var titleFocused: Bool

    private enum Phase: Equatable {
        case editing
        case creating
        case sending(cardID: String)
    }

    init(projectID: String, projectName: String, columns: [WireColumn], columnID: String?,
         connection: BoardConnection) {
        self.projectID = projectID
        self.projectName = projectName
        self.columns = columns
        self.connection = connection
        _columnID = State(initialValue: columnID ?? columns.first?.id ?? "")
    }

    private var column: WireColumn? { columns.first { $0.id == columnID } }
    private var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase == .editing }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("New card · \(column?.name ?? "") in \(projectName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Title", text: $title, axis: .vertical)
                    .font(.title.bold())
                    .focused($titleFocused)
                    .submitLabel(.next)
                    .onSubmit { controller.focus() }

                CardFieldChips(priority: $priority, dueDate: $dueDate, owner: $owner, tags: $tags)

                NotesEditor(text: $notes,
                            placeholder: "Notes. # for a heading, - for a list, [] for a checklist — or add a photo.",
                            controller: controller)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    NotesImageStrip(text: notes, projectID: projectID, connection: connection)
                    if case .sending = phase { progress }
                }
                .background(.bar)
            }
            .disabled(phase != .editing)
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .imageSources(controller) { picked in
            let id = UUID().uuidString
            staged[id] = picked
            connection.stage(picked.preview, as: id)
            controller.insertImageLine(PendingImage.markdown(name: picked.filename, uploadID: id))
        }
        .interactiveDismissDisabled(!title.isEmpty || !notes.isEmpty)
        .onAppear { titleFocused = true }
        .onChange(of: connection.heldDetails.keys.sorted()) { _, _ in finishIfSent() }
        .onChange(of: connection.lastFailure) { _, failure in
            // The Mac refused the card itself: back to editing, nothing lost.
            if failure != nil, phase == .creating { phase = .editing }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Cancel")
                .disabled(phase == .creating)
        }
        ToolbarItem(placement: .principal) {
            Menu {
                Picker("Column", selection: $columnID) {
                    ForEach(columns, id: \.id) { Text($0.name).tag($0.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Chip(text: column?.name ?? "Column", tint: Palette.column(column?.role), filled: true, dot: true)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .disabled(phase != .editing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: add) {
                if phase == .editing {
                    Text("Add").bold()
                } else {
                    ProgressView()
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!canAdd)
        }
    }

    /// "Sending to your Mac… 62%"
    private var progress: some View {
        let sending = PendingImage.ids(in: notes).compactMap { connection.uploads[$0] }
        let total = sending.reduce(0) { $0 + $1.data.count }
        let done = sending.reduce(0) { $0 + $1.received }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sending to your Mac…")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(total == 0 ? 1 : Double(done) / Double(total), format: .percent.precision(.fractionLength(0)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: total == 0 ? 1 : Double(done) / Double(total))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Adding

    private func add() {
        guard canAdd else { return }
        titleFocused = false
        phase = .creating
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.createCard(in: projectID, columnID: columnID, title: title) { cardID in
            send(to: cardID)
        }
    }

    private func send(to cardID: String) {
        if priority != .normal { connection.mutate(.setPriority(cardID: cardID, priority: priority), in: projectID) }
        if let dueDate { connection.mutate(.setDueDate(cardID: cardID, dueDate: dueDate), in: projectID) }
        if !owner.isEmpty { connection.mutate(.setOwner(cardID: cardID, owner: owner), in: projectID) }
        if !tags.isEmpty { connection.mutate(.setTags(cardID: cardID, tags: tags), in: projectID) }

        // Only the photos still in the notes: one whose line was deleted was
        // taken back.
        for id in PendingImage.ids(in: notes) {
            guard let picked = staged[id] else { continue }
            connection.upload(picked.data, filename: picked.filename, preview: picked.preview,
                              cardID: cardID, in: projectID, uploadID: id)
        }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connection.saveDetails(notes, cardID: cardID, in: projectID, previous: "")
        }
        phase = .sending(cardID: cardID)
        finishIfSent()
    }

    /// Closes once the notes have gone — which is once every photo has.
    private func finishIfSent() {
        guard case .sending(let cardID) = phase, connection.heldDetails[cardID] == nil else { return }
        dismiss()
    }
}
