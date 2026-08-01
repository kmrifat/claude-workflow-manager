//
//  BoardColumn.swift
//  workflow-manager
//
//  A stage on a project's board. First-class model rather than an enum so
//  every project can rename, add, remove and reorder its own workflow.
//

import Foundation
import SwiftData

@Model
final class BoardColumn {
    var uuid: UUID = UUID()
    var name: String = ""
    var sortOrder: Double = 0
    /// `nil` means unlimited.
    var wipLimit: Int?
    /// Items landing here count as done and get a `completedAt` stamp.
    var isCompletionColumn: Bool = false

    /// This column's meaning to the Claude sync, or `nil` for none. Optional
    /// with no default, so adding it stays a lightweight migration. See
    /// `ColumnRole` for why the mapping cannot key off `name`.
    var roleRaw: String?

    /// Inverse is declared on `Project.columns`.
    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \WorkItem.column)
    var items: [WorkItem] = []

    init(
        uuid: UUID = UUID(),
        name: String = "",
        sortOrder: Double = 0,
        wipLimit: Int? = nil,
        isCompletionColumn: Bool = false,
        role: ColumnRole? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.sortOrder = sortOrder
        self.wipLimit = wipLimit
        self.isCompletionColumn = isCompletionColumn
        self.roleRaw = role?.rawValue
        self.items = []
    }

    var role: ColumnRole? {
        get { roleRaw.flatMap(ColumnRole.init(rawValue:)) }
        set { roleRaw = newValue?.rawValue }
    }

    /// The column's cards, in board order.
    ///
    /// `isDeleted` is filtered here rather than at each call site. SwiftData
    /// leaves a deleted object in its relationship arrays until the context
    /// saves, so between a delete and the next autosave `items` still contains
    /// the card — and every reader got it wrong in its own way: the board drew
    /// it, the WIP count included it, the sync wrote it back to `tasks.json`.
    /// Making the accessor correct means a new reader cannot forget.
    var orderedItems: [WorkItem] {
        items.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var isOverWIP: Bool {
        guard let wipLimit else { return false }
        return orderedItems.count > wipLimit
    }
}
