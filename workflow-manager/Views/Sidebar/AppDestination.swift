//
//  AppDestination.swift
//  workflow-manager
//

import Foundation

/// What the detail pane shows — the sidebar's selection.
///
/// A project is held by `UUID`, never by model object, for the reason
/// `ContentView` has always given: a selection bound to a deleted `@Model` can
/// crash on the next render, whereas a stale UUID simply stops resolving.
enum AppDestination: Hashable {
    case overview
    case queue(CardQueue)
    case project(UUID)
    case settings

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}
