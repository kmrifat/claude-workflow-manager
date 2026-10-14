//
//  BoardView.swift
//  workflow-manager
//
//  Clicking a card shows it in a popover anchored to it (`CardPopover`);
//  double-clicking, or "Open in Window", opens it in its own window.
//
//  The keyboard works the board the way a pointer does: ←→↑↓ move the
//  selection — and the popover with it, if one is open — Space shows or hides
//  the popover, as Space does Quick Look, Return opens the card's window, Esc
//  closes the popover and then lets go, ⌘← ⌘→ carry the card to the next
//  lane, ⌘↑ ⌘↓ reorder it, and ⇧Tab goes back to the sidebar. Moves go
//  through `BoardMutations` like a drag, so ⌘Z undoes them. Where the arrows
//  land is `BoardNavigation`'s job.
//

import SwiftUI
import SwiftData

struct BoardView: View {
    @Environment(\.modelContext) private var context

    @Bindable var project: Project
    @Binding var selectedItemID: UUID?
    let filter: BoardFilter
    var focus: FocusState<FocusPane?>.Binding
    /// Return or a double-click on a card: its window.
    var onOpenItem: (WorkItem) -> Void = { _ in }

    /// The card whose popover is showing. Separate from the selection: a card
    /// stays selected after its popover closes, so ← → carry on from it.
    @State private var popoverItemID: UUID?

    /// Fixed width is required: a `LazyHStack` inside a horizontal
    /// `ScrollView` cannot size its children to content.
    static let columnWidth: CGFloat = 264

    @State private var isAddingColumn = false
    @State private var newColumnName = ""
    @FocusState private var newColumnFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            board
                .onChange(of: selectedItemID) { _, id in
                    // Bring the lane into view; the lane scrolls to the card.
                    guard let id, let column = project.allItems.first(where: { $0.uuid == id })?.column else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(column.uuid) }
                }
        }
        .focusable()
        .focused(focus, equals: .board)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        #if DEBUG
        .task {
            // `-ShowCard <title>`: that card's popover, for screenshots.
            if UserDefaults.standard.string(forKey: "ShowCard") != nil, let selectedItemID {
                try? await Task.sleep(for: .milliseconds(600))
                popoverItemID = selectedItemID
            }
        }
        #endif
    }

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(project.orderedColumns, id: \.uuid) { column in
                    BoardColumnView(
                        column: column,
                        selectedItemID: $selectedItemID,
                        filter: filter,
                        accent: project.accent.color,
                        focus: focus,
                        popoverItemID: $popoverItemID,
                        onOpenItem: onOpenItem
                    )
                    .frame(width: Self.columnWidth)
                    .id(column.uuid)
                }

                addColumnControl
                    .frame(width: Self.columnWidth)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            // Columns fill the height themselves, so this is currently a no-op —
            // but the default `.center` would silently start centering them the
            // moment one stops filling. See `GitHubIssuesView.columns`.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.background)
        .overlay {
            if project.columns.isEmpty {
                ContentUnavailableView {
                    Label("No Columns", systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Add a column to start building this project's workflow.")
                } actions: {
                    Button("Add Column") { beginAddingColumn() }
                }
            }
        }
    }

    // MARK: - Keyboard

    /// Each lane's cards as the keyboard sees them: in order, without the ones
    /// a filter dims.
    private var lanes: [[WorkItem]] {
        project.orderedColumns.map { column in
            column.orderedItems.filter { !filter.isActive || filter.matches($0) }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // ⇧Tab arrives as a back-tab character on macOS, not as Tab + Shift.
        if press.key == .tab || press.key.character == "\u{19}" {
            guard press.modifiers.contains(.shift) || press.key.character == "\u{19}" else { return .ignored }
            focus.wrappedValue = .sidebar
            return .handled
        }

        let lanes = lanes
        let ids = lanes.map { $0.map(\.uuid) }
        let position = BoardNavigation.locate(selectedItemID, in: ids)
        let command = press.modifiers.contains(.command)

        switch press.key {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            guard let position else {
                // Nothing selected yet: any arrow starts at the first card.
                selectedItemID = BoardNavigation.first(in: ids)
                return .handled
            }
            let vertical = press.key == .upArrow || press.key == .downArrow
            let delta = (press.key == .upArrow || press.key == .leftArrow) ? -1 : 1
            let item = lanes[position.lane][position.row]
            if command {
                withAnimation(.snappy(duration: 0.2)) {
                    vertical ? reorder(item, by: delta) : carry(item, by: delta)
                }
            } else if let next = vertical
                        ? BoardNavigation.vertical(from: position, by: delta, in: ids)
                        : BoardNavigation.horizontal(from: position, by: delta, in: ids) {
                selectedItemID = next
                // An open popover follows the selection, as Quick Look does.
                if popoverItemID != nil { popoverItemID = next }
            }
        case .space:
            guard let id = selectedItemID ?? BoardNavigation.first(in: ids) else { return .ignored }
            selectedItemID = id
            popoverItemID = popoverItemID == id ? nil : id
        case .return:
            guard let position else { return .ignored }
            popoverItemID = nil
            onOpenItem(lanes[position.lane][position.row])
        case .escape:
            if popoverItemID != nil {
                popoverItemID = nil
            } else if selectedItemID != nil {
                selectedItemID = nil
            } else {
                return .ignored
            }
        default:
            return .ignored
        }
        return .handled
    }

    /// ⌘↑ ⌘↓: one place up or down its lane, counted over every card in the
    /// lane, so a dimmed card in between is stepped over rather than lost.
    private func reorder(_ item: WorkItem, by delta: Int) {
        guard let column = item.column,
              let index = column.orderedItems.firstIndex(where: { $0.uuid == item.uuid }) else { return }
        let target = index + delta
        guard column.orderedItems.indices.contains(target) else { return }
        BoardMutations.move(item, to: column, insertingAt: target)
    }

    /// ⌘← ⌘→: into the neighbouring lane at the same height, the way a drag
    /// across would drop it.
    private func carry(_ item: WorkItem, by delta: Int) {
        let columns = project.orderedColumns
        guard let column = item.column,
              let index = columns.firstIndex(where: { $0.uuid == column.uuid }),
              columns.indices.contains(index + delta) else { return }
        let row = column.orderedItems.firstIndex(where: { $0.uuid == item.uuid }) ?? 0
        BoardMutations.move(item, to: columns[index + delta], insertingAt: row)
    }

    private var addColumnControl: some View {
        Group {
            if isAddingColumn {
                TextField("Column name", text: $newColumnName)
                    .textFieldStyle(.plain)
                    .focused($newColumnFocused)
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    .onSubmit(commitNewColumn)
                    .onExitCommand { cancelAddingColumn() }
                    .onChange(of: newColumnFocused) { _, focused in
                        if !focused { cancelAddingColumn() }
                    }
            } else {
                Button(action: beginAddingColumn) {
                    Label("Add Column", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Theme.lane, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func beginAddingColumn() {
        newColumnName = ""
        isAddingColumn = true
        newColumnFocused = true
    }

    private func commitNewColumn() {
        let trimmed = newColumnName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cancelAddingColumn() }
        withAnimation(.snappy) {
            _ = BoardMutations.addColumn(named: trimmed, to: project, in: context)
        }
        newColumnName = ""
        newColumnFocused = true
    }

    private func cancelAddingColumn() {
        newColumnName = ""
        isAddingColumn = false
        newColumnFocused = false
    }
}

#if DEBUG
#Preview {
    @Previewable @State var inspected: UUID?
    @Previewable @FocusState var focus: FocusPane?
    if let project = SampleData.firstProject {
        BoardView(project: project, selectedItemID: $inspected, filter: BoardFilter(), focus: $focus)
            .modelContainer(SampleData.container)
            .frame(width: 1100, height: 620)
    }
}
#endif
