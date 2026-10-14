//
//  BoardFilter.swift
//  workflow-manager
//
//  All filtering runs in memory: `WorkItem.tags` is persisted as a blob and
//  cannot appear in a `#Predicate`, and a board holds few enough cards that
//  querying per keystroke would be wasted work.
//

import Foundation

/// The scope bar's segments above the board: one quick cut of the cards.
enum BoardScope: String, CaseIterable, Identifiable {
    case all, claude, blocked, overdue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:     "All"
        case .claude:  "Claude"
        case .blocked: "Blocked"
        case .overdue: "Overdue"
        }
    }
}

struct BoardFilter: Equatable {
    var searchText: String = ""
    var scope: BoardScope = .all
    var minimumPriority: Priority?
    var overdueOnly: Bool = false
    var owner: String?
    var tag: String?

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || scope != .all
            || minimumPriority != nil
            || overdueOnly
            || owner != nil
            || tag != nil
    }

    func matches(_ item: WorkItem) -> Bool {
        guard item.matches(searchText) else { return false }
        switch scope {
        case .all: break
        case .claude: if item.agentState == .none { return false }
        case .blocked: if !item.isBlocked { return false }
        case .overdue: if !item.isOverdue { return false }
        }
        if let minimumPriority, item.priority < minimumPriority { return false }
        if overdueOnly, !item.isOverdue { return false }
        if let owner, item.owner != owner { return false }
        if let tag, !item.tags.contains(tag) { return false }
        return true
    }

    mutating func clear() {
        self = BoardFilter()
    }
}
