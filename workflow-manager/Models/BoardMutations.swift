//
//  BoardMutations.swift
//  workflow-manager
//
//  Every change to ordering or column membership goes through here, so the
//  fractional-order invariants live in exactly one place.
//

import Foundation
import SwiftData

enum BoardMutations {

    // MARK: - Work items

    /// Moves `item` into `column` at `index`, computed against the column's
    /// items *excluding* the item being moved (which makes same-column
    /// reordering fall out correctly).
    static func move(_ item: WorkItem, to column: BoardColumn, insertingAt index: Int) {
        var ordered = column.orderedItems.filter { $0.uuid != item.uuid }
        let target = min(max(index, 0), ordered.count)

        let previous = target > 0 ? ordered[target - 1].sortOrder : nil
        let next = target < ordered.count ? ordered[target].sortOrder : nil
        item.sortOrder = FractionalOrder.between(previous, next)

        // Only ever set the to-one side; SwiftData maintains the inverse.
        if item.column !== column {
            item.column = column
        }

        applyCompletionState(to: item, movedInto: column)

        ordered.insert(item, at: target)
        if FractionalOrder.needsNormalization(ordered.map(\.sortOrder)) {
            normalize(ordered)
        }
    }

    static func append(_ item: WorkItem, to column: BoardColumn) {
        move(item, to: column, insertingAt: column.orderedItems.count)
    }

    /// Creates a work item at the end of `column`.
    @discardableResult
    static func addItem(
        titled title: String,
        to column: BoardColumn,
        in context: ModelContext
    ) -> WorkItem {
        let item = WorkItem(title: title)
        context.insert(item)
        append(item, to: column)
        return item
    }

    static func duplicate(_ item: WorkItem, in context: ModelContext) {
        guard let column = item.column else { return }
        let copy = WorkItem(
            title: item.title.isEmpty ? "Copy" : "\(item.title) copy",
            details: item.details,
            priority: item.priority,
            startDate: item.startDate,
            dueDate: item.dueDate,
            owner: item.owner,
            tags: item.tags
        )
        context.insert(copy)
        for subtask in item.orderedSubtasks {
            let subCopy = Subtask(title: subtask.title, sortOrder: subtask.sortOrder)
            context.insert(subCopy)
            subCopy.item = copy
        }
        let index = column.orderedItems.firstIndex { $0.uuid == item.uuid }
        move(copy, to: column, insertingAt: (index ?? column.orderedItems.count - 1) + 1)
    }

    /// Keeps `completedAt` in step with whichever column the item now lives in.
    private static func applyCompletionState(to item: WorkItem, movedInto column: BoardColumn) {
        if column.isCompletionColumn {
            if item.completedAt == nil { item.completedAt = .now }
        } else {
            item.completedAt = nil
        }
    }

    private static func normalize(_ ordered: [WorkItem]) {
        let orders = FractionalOrder.normalizedOrders(count: ordered.count)
        for (item, order) in zip(ordered, orders) {
            item.sortOrder = order
        }
    }

    // MARK: - Columns

    /// Roles are assigned here so a brand-new project can sync with Claude
    /// without the user configuring anything. "Backlog" deliberately has no
    /// role: `todo` belongs to exactly one column, and two columns claiming it
    /// would make the reverse mapping ambiguous.
    static let defaultColumnSpecs: [
        (name: String, wipLimit: Int?, isCompletion: Bool, role: ColumnRole?)
    ] = [
        ("Backlog", nil, false, nil),
        ("To Do", nil, false, .todo),
        ("In Progress", 3, false, .inProgress),
        ("Review", nil, false, .review),
        ("Done", nil, true, .done),
    ]

    static func makeDefaultColumns(for project: Project, in context: ModelContext) {
        for (index, spec) in defaultColumnSpecs.enumerated() {
            let column = BoardColumn(
                name: spec.name,
                sortOrder: Double(index + 1) * FractionalOrder.step,
                wipLimit: spec.wipLimit,
                isCompletionColumn: spec.isCompletion,
                role: spec.role
            )
            context.insert(column)
            column.project = project
        }
    }

    /// Gives `column` a sync role, taking it off any sibling that held it.
    ///
    /// Same shape as `setCompletionColumn`, and for the same reason: the mapping
    /// from a status back to a column has to be single-valued.
    static func setRole(_ role: ColumnRole?, on column: BoardColumn) {
        if let role, let project = column.project {
            for other in project.columns where other.uuid != column.uuid {
                if other.role == role { other.role = nil }
            }
        }
        column.role = role

        // `done` and the completion column mean the same thing to a person;
        // letting them disagree would put a card in "Done" with no `completedAt`.
        if role == .done {
            setCompletionColumn(column)
        }
    }

    @discardableResult
    static func addColumn(
        named name: String,
        to project: Project,
        in context: ModelContext
    ) -> BoardColumn {
        let column = BoardColumn(
            name: name,
            sortOrder: FractionalOrder.afterLast(of: project.columns.map(\.sortOrder))
        )
        context.insert(column)
        column.project = project
        return column
    }

    /// Shifts a column one slot left or right on its board.
    static func moveColumn(_ column: BoardColumn, by offset: Int) {
        guard let project = column.project else { return }
        let ordered = project.orderedColumns
        guard let current = ordered.firstIndex(where: { $0.uuid == column.uuid }) else { return }
        let target = current + offset
        guard ordered.indices.contains(target) else { return }

        var rest = ordered
        rest.remove(at: current)
        let previous = target > 0 ? rest[target - 1].sortOrder : nil
        let next = target < rest.count ? rest[target].sortOrder : nil
        column.sortOrder = FractionalOrder.between(previous, next)

        rest.insert(column, at: target)
        if FractionalOrder.needsNormalization(rest.map(\.sortOrder)) {
            let orders = FractionalOrder.normalizedOrders(count: rest.count)
            for (item, order) in zip(rest, orders) { item.sortOrder = order }
        }
    }

    /// Marks a single column as *the* completion column for its project.
    static func setCompletionColumn(_ column: BoardColumn) {
        guard let project = column.project else { return }
        for other in project.columns where other.uuid != column.uuid {
            other.isCompletionColumn = false
        }
        column.isCompletionColumn = true
        for item in column.items where item.completedAt == nil {
            item.completedAt = .now
        }
    }

    /// Deletes a column, relocating its items to the neighbour on the left
    /// (or right) so work is never silently destroyed.
    static func deleteColumn(_ column: BoardColumn, in context: ModelContext) {
        if let project = column.project {
            let ordered = project.orderedColumns
            if let index = ordered.firstIndex(where: { $0.uuid == column.uuid }) {
                let fallback = index > 0 ? ordered[index - 1]
                    : (ordered.count > 1 ? ordered[1] : nil)
                if let fallback {
                    for item in column.orderedItems {
                        append(item, to: fallback)
                    }
                }
            }
        }
        context.delete(column)
    }

    // MARK: - Projects

    @discardableResult
    static func createProject(from draft: ProjectDraft, in context: ModelContext, existing: [Project]) -> Project {
        let project = Project(
            name: draft.trimmedName,
            summary: draft.summary,
            goal: draft.goal,
            plan: draft.plan,
            startDate: draft.startDate,
            targetEndDate: draft.hasTargetEnd ? draft.targetEndDate : nil,
            status: draft.status,
            accent: draft.accent,
            symbolName: draft.symbolName,
            sortOrder: FractionalOrder.afterLast(of: existing.map(\.sortOrder))
        )
        context.insert(project)
        makeDefaultColumns(for: project, in: context)
        return project
    }

    /// Creates a project already linked to a local clone.
    ///
    /// Seeded from the repository rather than asking the user to retype it: the
    /// name and slug are already known. No target end date is invented — a
    /// repository has no deadline of its own.
    @discardableResult
    static func createProject(
        forRepository repository: GitHubRepository,
        at directory: URL,
        in context: ModelContext,
        existing: [Project]
    ) -> Project {
        var draft = ProjectDraft()
        draft.name = repository.name
        draft.summary = repository.slug
        draft.status = .active
        draft.symbolName = "chevron.left.forwardslash.chevron.right"
        draft.hasTargetEnd = false

        let project = createProject(from: draft, in: context, existing: existing)
        project.repoPath = Project.canonicalRepoPath(directory)
        project.repoOwner = repository.owner
        project.repoName = repository.name
        project.repoDefaultBranch = repository.defaultBranch
        return project
    }

    static func apply(_ draft: ProjectDraft, to project: Project) {
        project.name = draft.trimmedName
        project.summary = draft.summary
        project.goal = draft.goal
        project.plan = draft.plan
        project.startDate = draft.startDate
        project.targetEndDate = draft.hasTargetEnd ? draft.targetEndDate : nil
        project.status = draft.status
        project.accent = draft.accent
        project.symbolName = draft.symbolName
    }

    static func duplicate(_ project: Project, in context: ModelContext, existing: [Project]) {
        let copy = Project(
            name: "\(project.name) copy",
            summary: project.summary,
            goal: project.goal,
            plan: project.plan,
            startDate: project.startDate,
            targetEndDate: project.targetEndDate,
            status: .planning,
            accent: project.accent,
            symbolName: project.symbolName,
            sortOrder: FractionalOrder.afterLast(of: existing.map(\.sortOrder))
        )
        context.insert(copy)

        for column in project.orderedColumns {
            let columnCopy = BoardColumn(
                name: column.name,
                sortOrder: column.sortOrder,
                wipLimit: column.wipLimit,
                isCompletionColumn: column.isCompletionColumn,
                role: column.role
            )
            context.insert(columnCopy)
            columnCopy.project = copy

            for item in column.orderedItems {
                let itemCopy = WorkItem(
                    title: item.title,
                    details: item.details,
                    priority: item.priority,
                    startDate: item.startDate,
                    dueDate: item.dueDate,
                    owner: item.owner,
                    tags: item.tags,
                    sortOrder: item.sortOrder
                )
                context.insert(itemCopy)
                itemCopy.column = columnCopy
                if columnCopy.isCompletionColumn { itemCopy.completedAt = item.completedAt }
            }
        }
    }
}
