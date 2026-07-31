//
//  AppModelContainer.swift
//  workflow-manager
//

import Foundation
import SwiftData

@MainActor
enum AppModelContainer {
    static let schema = Schema([
        Project.self,
        BoardColumn.self,
        WorkItem.self,
        Subtask.self,
        TerminalCommand.self,
        // A disposable cache, not board data. See `IssueCacheEntry`.
        IssueCacheEntry.self,
    ])

    /// The configuration is *named*, which puts the store in
    /// `WorkflowManager.store` instead of `default.store`. Any leftover
    /// `default.store` from the Xcode template's `Item` entity is therefore
    /// ignored rather than failing to open.
    static func make(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            "WorkflowManager",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            // One dirtied object per drag means ⌘Z undoes exactly one move.
            container.mainContext.undoManager = UndoManager()
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
