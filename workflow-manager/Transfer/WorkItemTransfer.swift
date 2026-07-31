//
//  WorkItemTransfer.swift
//  workflow-manager
//
//  `@Model` classes are context-managed reference types and can't sensibly be
//  `Transferable`. The drag payload is therefore a plain value carrying the
//  item's stable app-level `UUID`, which the drop site re-fetches from its own
//  `ModelContext`. (A `PersistentIdentifier` is `Codable` and tempting, but it
//  encodes store-internal coordinates that break across process boundaries.)
//

import Foundation
import CoreTransferable
import OSLog
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static let workItemDrag = UTType(exportedAs: "com.binarycastle.workflow-manager.workitem")
}

struct WorkItemTransfer: Codable, Transferable, Hashable, Sendable {
    var itemID: UUID
    var sourceColumnID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .workItemDrag)
    }
}

extension WorkItem {
    /// Fallback lookup. Prefer resolving against an already-loaded object
    /// graph (`Project.allItems`): a `#Predicate` on a `UUID` is fragile, and
    /// a fetch can miss objects still pending insert in the context.
    static func fetch(_ id: UUID, in context: ModelContext) -> WorkItem? {
        var descriptor = FetchDescriptor<WorkItem>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            Log.dragAndDrop.error("WorkItem fetch for \(id, privacy: .public) failed: \(error)")
            return nil
        }
    }
}

extension BoardColumn {
    static func fetch(_ id: UUID, in context: ModelContext) -> BoardColumn? {
        var descriptor = FetchDescriptor<BoardColumn>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            Log.dragAndDrop.error("BoardColumn fetch for \(id, privacy: .public) failed: \(error)")
            return nil
        }
    }
}
