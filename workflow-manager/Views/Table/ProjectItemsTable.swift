//
//  ProjectItemsTable.swift
//  workflow-manager
//
//  Flat sortable view of every work item in the project.
//

import SwiftUI
import SwiftData

struct ProjectItemsTable: View {
    @Environment(\.modelContext) private var context

    @Bindable var project: Project
    @Binding var inspectedItemID: UUID?
    let filter: BoardFilter

    @State private var sortOrder = [KeyPathComparator(\WorkItemRow.dueSortKey)]

    /// SwiftUI's `Table` wants value rows; the model objects stay reachable
    /// through the row's `uuid`.
    private var rows: [WorkItemRow] {
        project.orderedColumns
            .flatMap { column in
                column.orderedItems
                    .filter { !filter.isActive || filter.matches($0) }
                    .map { WorkItemRow(item: $0, columnName: column.name) }
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Items",
                    systemImage: "list.bullet",
                    description: Text(filter.isActive
                                      ? "No items match the current filter."
                                      : "Add items on the board to see them listed here.")
                )
            } else {
                Table(rows, selection: selectionBinding, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \.title) { row in
                        HStack(spacing: 6) {
                            Circle().fill(row.priorityColor).frame(width: 6, height: 6)
                            Text(row.title)
                                .strikethrough(row.isDone, color: .secondary)
                        }
                    }
                    TableColumn("Column", value: \.columnName)
                    TableColumn("Priority", value: \.prioritySortKey) { row in
                        Text(row.priorityTitle)
                    }
                    TableColumn("Owner", value: \.owner)
                    TableColumn("Due", value: \.dueSortKey) { row in
                        Text(row.dueLabel)
                            .foregroundStyle(row.isOverdue ? Color.red : .primary)
                    }
                    TableColumn("Checklist", value: \.checklistSortKey) { row in
                        Text(row.checklistLabel).foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first {
                        Button("Edit Details") { inspectedItemID = id }
                        Button("Delete", role: .destructive) { delete(ids) }
                    }
                } primaryAction: { ids in
                    inspectedItemID = ids.first
                }
            }
        }
        .background(.background)
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { inspectedItemID.map { [$0] } ?? [] },
            set: { inspectedItemID = $0.first }
        )
    }

    private func delete(_ ids: Set<UUID>) {
        for id in ids {
            guard let item = WorkItem.fetch(id, in: context) else { continue }
            if inspectedItemID == id { inspectedItemID = nil }
            context.delete(item)
        }
    }
}

/// Snapshot of a work item for `Table`, which needs `Identifiable` values
/// with comparable sort keys.
struct WorkItemRow: Identifiable {
    let id: UUID
    let title: String
    let columnName: String
    let owner: String
    let priorityTitle: String
    let prioritySortKey: Int
    let dueDate: Date?
    let isOverdue: Bool
    let isDone: Bool
    let completedSubtasks: Int
    let totalSubtasks: Int
    let priorityColor: Color

    init(item: WorkItem, columnName: String) {
        id = item.uuid
        title = item.title.isEmpty ? "Untitled" : item.title
        self.columnName = columnName
        owner = item.owner
        priorityTitle = item.priority.title
        prioritySortKey = -item.priority.rawValue
        dueDate = item.dueDate
        isOverdue = item.isOverdue
        isDone = item.isDone
        completedSubtasks = item.completedSubtaskCount
        totalSubtasks = item.subtasks.count
        priorityColor = item.priority.color
    }

    /// Undated items sort last.
    var dueSortKey: Date { dueDate ?? .distantFuture }

    var dueLabel: String {
        dueDate.map(DateHelpers.chipLabel) ?? "—"
    }

    var checklistSortKey: Int { totalSubtasks == 0 ? -1 : completedSubtasks }

    var checklistLabel: String {
        totalSubtasks == 0 ? "—" : "\(completedSubtasks)/\(totalSubtasks)"
    }
}

#if DEBUG
#Preview {
    @Previewable @State var inspected: UUID?
    if let project = SampleData.firstProject {
        ProjectItemsTable(project: project, inspectedItemID: $inspected, filter: BoardFilter())
            .modelContainer(SampleData.container)
            .frame(width: 900, height: 500)
    }
}
#endif
