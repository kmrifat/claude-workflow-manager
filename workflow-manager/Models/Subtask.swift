//
//  Subtask.swift
//  workflow-manager
//

import Foundation
import SwiftData

@Model
final class Subtask {
    var uuid: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var sortOrder: Double = 0

    /// Inverse is declared on `WorkItem.subtasks`.
    var item: WorkItem?

    init(
        uuid: UUID = UUID(),
        title: String = "",
        isDone: Bool = false,
        sortOrder: Double = 0
    ) {
        self.uuid = uuid
        self.title = title
        self.isDone = isDone
        self.sortOrder = sortOrder
    }
}
