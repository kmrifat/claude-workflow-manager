//
//  AppDestination.swift
//  workflow-manager
//

import Foundation
import SwiftUI

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

/// Which half of the window has the keyboard. Tab moves from the sidebar into
/// the detail, ⇧Tab moves back, and each side handles its own arrow keys.
///
/// One `@FocusState` in `ContentView` rather than one per view, because moving
/// between the halves means one side has to hand focus to the other.
///
/// `.content` is a detail view that is a list of its own — Files' tree, the
/// List view's table. It has to be a pane rather than left to AppKit: the
/// sidebar takes the keyboard on every click, and a list nothing hands it back
/// to kept its selection grey while ↑↓ went on walking the sidebar.
enum FocusPane: Hashable {
    case sidebar
    case board
    case content
}

extension View {
    /// `.focused(_:equals:)` when there is a binding — previews have none —
    /// plus ⇧Tab back to the sidebar, the way the board does it.
    @ViewBuilder
    func pane(_ focus: FocusState<FocusPane?>.Binding?, _ pane: FocusPane) -> some View {
        if let focus {
            self
                .focused(focus, equals: pane)
                .onKeyPress(.tab, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    focus.wrappedValue = .sidebar
                    return .handled
                }
        } else {
            self
        }
    }
}
