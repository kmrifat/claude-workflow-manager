//
//  BoardColumnView.swift
//  workflow-manager
//
//  Drop targets are layered rather than computed from one big frame:
//  `.dropDestination` reports no continuous drag location (its `isTargeted` is
//  a bare `Bool`), so each card is its own target and decides insert-before vs
//  insert-after from the drop's local `y`. The header prepends, the column
//  background appends.
//

import SwiftUI
import OSLog
import SwiftData

struct BoardColumnView: View {
    @Environment(\.modelContext) private var context

    @Bindable var column: BoardColumn
    @Binding var inspectedItemID: UUID?
    let filter: BoardFilter
    let accent: Color

    @State private var hoveredCardID: UUID?
    @State private var dropsAfterHovered = false
    @State private var isColumnTargeted = false
    @State private var isHeaderTargeted = false
    @State private var cardHeights: [UUID: CGFloat] = [:]
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    /// The card whose popover is open. A `UUID` rather than the model object,
    /// for the same reason selection is elsewhere: a deleted `@Model` bound to a
    /// presentation can crash on the next render, a stale UUID just stops
    /// resolving.
    @State private var popoverItemID: UUID?
    /// Sheets the popover asks for. Hosted here rather than inside the popover:
    /// on macOS a sheet presented from a popover is torn down with it when
    /// focus moves.
    @State private var creatingIssueForID: UUID?
    @State private var linkingIssueForID: UUID?
    /// Cached issues, read once per column to know which labels the repository
    /// actually has. `gh issue create` fails outright on an unknown label.
    @State private var repositoryLabels: [String] = []
    @State private var showsAllDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 4) {
                cardList
                QuickAddField(placeholder: "Card title") { title in
                    withAnimation(.snappy(duration: 0.2)) {
                        _ = BoardMutations.addItem(titled: title, to: column, in: context)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .background(Theme.lane, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isColumnTargeted ? accent : .clear, lineWidth: 2)
            }
        }
        // Lowest-priority target: anything not caught by a card or the header
        // appends to the end of this column.
        .dropDestination(for: WorkItemTransfer.self) { payloads, _ in
            perform(payloads) { dragged in
                BoardMutations.append(dragged, to: column)
            }
        } isTargeted: { isColumnTargeted = $0 }
        .task(id: column.project?.repoPath) {
            guard let project = column.project, project.hasRepository else {
                repositoryLabels = []
                return
            }
            // From the cache only — opening a board must not spawn `gh`.
            let issues = await IssueCache.load(for: project, in: context)?.issues ?? []
            repositoryLabels = Set(issues.flatMap { $0.labels.map(\.name) }).sorted()
        }
        .sheet(isPresented: sheetBinding(for: $creatingIssueForID)) {
            if let item = item(for: creatingIssueForID), let project = column.project {
                CreateIssueSheet(
                    item: item,
                    project: project,
                    availableLabels: repositoryLabels,
                    onCreated: { created in
                        IssueLinking.link(
                            item,
                            toIssueNumber: created.number,
                            slug: project.repoSlug
                        )
                    }
                )
            }
        }
        .sheet(isPresented: sheetBinding(for: $linkingIssueForID)) {
            if let item = item(for: linkingIssueForID), let project = column.project {
                IssuePickerSheet(
                    project: project,
                    claimed: IssueLinking.linkedNumbers(in: project),
                    currentSelection: item.githubIssueNumber,
                    onPick: { IssueLinking.link(item, to: $0) }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if isRenaming {
                TextField("Column name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Circle()
                    .fill(column.tint)
                    .frame(width: 8, height: 8)
                    .help(column.role.map { "Claude status: \($0.title)" } ?? "No Claude status")

                Text(column.name.isEmpty ? "Untitled" : column.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: beginRename)

                countBadge

                Spacer(minLength: 0)

                Button {
                    let item = withAnimation(.snappy(duration: 0.2)) {
                        BoardMutations.addItem(titled: "New item", to: column, in: context)
                    }
                    inspectedItemID = item.uuid
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a card to \(column.name)")

                columnMenu
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(alignment: .bottom) {
            if isHeaderTargeted {
                Capsule().fill(accent).frame(height: 3).padding(.horizontal, 10)
            }
        }
        // Dropping on the header puts the item at the top of the column.
        .dropDestination(for: WorkItemTransfer.self) { payloads, _ in
            perform(payloads) { dragged in
                BoardMutations.move(dragged, to: column, insertingAt: 0)
            }
        } isTargeted: { isHeaderTargeted = $0 }
    }

    /// A plain count, or "2/3" in a pill when the column has a WIP limit —
    /// red once it is over.
    @ViewBuilder
    private var countBadge: some View {
        let count = column.orderedItems.count
        if let limit = column.wipLimit {
            Text("\(count)/\(limit)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(column.isOverWIP ? Theme.danger : .secondary)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(column.isOverWIP ? Theme.danger.opacity(0.15) : Color.primary.opacity(0.07),
                            in: .rect(cornerRadius: 4))
                .help(column.isOverWIP ? "Over the WIP limit" : "Cards / WIP limit")
        } else {
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var columnMenu: some View {
        Menu {
            Button("Rename…", action: beginRename)

            Menu("WIP Limit") {
                Button("None") { column.wipLimit = nil }
                Divider()
                ForEach(1...10, id: \.self) { limit in
                    Button(limit == column.wipLimit ? "✓ \(limit)" : "\(limit)") {
                        column.wipLimit = limit
                    }
                }
            }

            Button(column.isCompletionColumn ? "Completion Column ✓" : "Mark as Completion Column") {
                BoardMutations.setCompletionColumn(column)
            }
            .disabled(column.isCompletionColumn)

            // What a Claude session's `status` value means for this column.
            // Named separately from the column itself because columns can be
            // renamed and the agent's vocabulary cannot.
            Menu("Claude Status") {
                Button(column.role == nil ? "None ✓" : "None") {
                    BoardMutations.setRole(nil, on: column)
                }
                Divider()
                ForEach(ColumnRole.allCases) { role in
                    Button(column.role == role ? "\(role.title) ✓" : role.title) {
                        BoardMutations.setRole(role, on: column)
                    }
                }
            }

            Divider()

            Button("Move Left") {
                withAnimation(.snappy) { BoardMutations.moveColumn(column, by: -1) }
            }
            Button("Move Right") {
                withAnimation(.snappy) { BoardMutations.moveColumn(column, by: 1) }
            }

            Divider()

            Button("Delete Column", role: .destructive) {
                withAnimation(.snappy) { BoardMutations.deleteColumn(column, in: context) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Cards

    /// A completion column lists its cards compactly and shows the first few:
    /// done work is a record, and twenty full cards would push everything else
    /// off screen.
    private static let compactVisibleCount = 8

    private var visibleItems: [WorkItem] {
        let items = column.orderedItems
        guard column.isCompletionColumn, !showsAllDone else { return items }
        return Array(items.prefix(Self.compactVisibleCount))
    }

    private var cardList: some View {
        ScrollView(.vertical) {
            // Not lazy: a lane holds a handful of cards, and `LazyVStack`
            // mis-estimated a queued card's extra height and opened the lane
            // scrolled past its first card.
            VStack(spacing: column.isCompletionColumn ? 1 : 6) {
                ForEach(visibleItems, id: \.uuid) { item in
                    card(for: item)
                }

                let hidden = column.orderedItems.count - visibleItems.count
                if hidden > 0 || (showsAllDone && column.orderedItems.count > Self.compactVisibleCount) {
                    Button(showsAllDone ? "Show fewer" : "Show \(hidden) more") {
                        withAnimation(.snappy) { showsAllDone.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                }

                if column.items.isEmpty {
                    Text("Drop cards here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                }
            }
            .padding(6)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func card(for item: WorkItem) -> some View {
        WorkItemCardView(
            item: item,
            isSelected: inspectedItemID == item.uuid || popoverItemID == item.uuid,
            isDimmed: filter.isActive && !filter.matches(item),
            accent: accent,
            isCompact: column.isCompletionColumn
        )
        .overlay(alignment: hoveredCardID == item.uuid && dropsAfterHovered ? .bottom : .top) {
            if hoveredCardID == item.uuid {
                Capsule()
                    .fill(accent)
                    .frame(height: 3)
                    .offset(y: dropsAfterHovered ? 5 : -5)
            }
        }
        .onTapGesture {
            popoverItemID = (popoverItemID == item.uuid) ? nil : item.uuid
        }
        .popover(
            isPresented: popoverBinding(for: item),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing
        ) {
            WorkItemPopover(
                item: item,
                accent: accent,
                onEditDetails: { inspectedItemID = item.uuid },
                onDelete: {
                    withAnimation(.snappy) { context.delete(item) }
                },
                onCreateIssue: { creatingIssueForID = item.uuid },
                onLinkIssue: { linkingIssueForID = item.uuid }
            )
        }
        .draggable(WorkItemTransfer(itemID: item.uuid, sourceColumnID: column.uuid)) {
            WorkItemCardView(item: item, accent: accent, isCompact: column.isCompletionColumn)
                .frame(width: BoardView.columnWidth - 12)
                .opacity(0.9)
        }
        .dropDestination(for: WorkItemTransfer.self) { payloads, location in
            let height = cardHeights[item.uuid] ?? 60
            let after = location.y > height / 2
            return perform(payloads) { dragged in
                guard dragged.uuid != item.uuid else { return }
                let ordered = column.orderedItems.filter { $0.uuid != dragged.uuid }
                let anchor = ordered.firstIndex { $0.uuid == item.uuid } ?? ordered.count
                BoardMutations.move(dragged, to: column, insertingAt: after ? anchor + 1 : anchor)
            }
        } isTargeted: { targeted in
            hoveredCardID = targeted ? item.uuid : (hoveredCardID == item.uuid ? nil : hoveredCardID)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            cardHeights[item.uuid] = height
        }
        .contextMenu { cardMenu(for: item) }
    }

    @ViewBuilder
    private func cardMenu(for item: WorkItem) -> some View {
        Button("Edit Details") { inspectedItemID = item.uuid }

        if let project = column.project {
            Menu("Move to") {
                ForEach(project.orderedColumns, id: \.uuid) { destination in
                    Button(destination.name) {
                        withAnimation(.snappy) {
                            BoardMutations.append(item, to: destination)
                        }
                    }
                    .disabled(destination.uuid == column.uuid)
                }
            }
        }

        Menu("Priority") {
            ForEach(Priority.allCases) { priority in
                Button(priority == item.priority ? "✓ \(priority.title)" : priority.title) {
                    item.priority = priority
                }
            }
        }

        Button("Duplicate") {
            withAnimation(.snappy) { BoardMutations.duplicate(item, in: context) }
        }

        Divider()

        Button("Delete", role: .destructive) {
            if inspectedItemID == item.uuid { inspectedItemID = nil }
            if popoverItemID == item.uuid { popoverItemID = nil }
            withAnimation(.snappy) { context.delete(item) }
        }
    }

    // MARK: - Helpers

    /// Resolves a card id back to a live, undeleted item in this column.
    private func item(for id: UUID?) -> WorkItem? {
        guard let id else { return nil }
        return column.orderedItems.first { $0.uuid == id }
    }

    /// Presents while an id is set, and clears it on dismissal.
    private func sheetBinding(for id: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { id.wrappedValue != nil },
            set: { if !$0 { id.wrappedValue = nil } }
        )
    }

    private func popoverBinding(for item: WorkItem) -> Binding<Bool> {
        Binding(
            get: { popoverItemID == item.uuid },
            set: { isShown in
                if isShown { popoverItemID = item.uuid }
                else if popoverItemID == item.uuid { popoverItemID = nil }
            }
        )
    }

    /// Resolves the dragged item and applies `body`. Both failure modes are
    /// logged: a rejected drop is otherwise indistinguishable from nothing
    /// happening at all.
    private func perform(
        _ payloads: [WorkItemTransfer],
        _ body: (WorkItem) -> Void
    ) -> Bool {
        guard let payload = payloads.first else {
            Log.dragAndDrop.error("Drop on \(column.name, privacy: .public) carried no payload")
            hoveredCardID = nil
            return false
        }

        // Resolve from the loaded object graph first: the dragged card is by
        // definition in this project, so this needs no predicate and no save.
        let dragged = column.project?.allItems.first { $0.uuid == payload.itemID }
            ?? WorkItem.fetch(payload.itemID, in: context)

        guard let dragged else {
            Log.dragAndDrop.error(
                "Drop on \(column.name, privacy: .public) could not resolve item \(payload.itemID, privacy: .public)"
            )
            hoveredCardID = nil
            return false
        }

        withAnimation(.snappy(duration: 0.22)) { body(dragged) }
        hoveredCardID = nil
        return true
    }

    private func beginRename() {
        draftName = column.name
        isRenaming = true
        nameFieldFocused = true
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { column.name = trimmed }
        isRenaming = false
    }
}
