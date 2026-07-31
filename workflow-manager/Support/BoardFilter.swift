//
//  BoardFilter.swift
//  workflow-manager
//
//  All filtering runs in memory: `WorkItem.tags` is persisted as a blob and
//  cannot appear in a `#Predicate`, and a board holds few enough cards that
//  querying per keystroke would be wasted work.
//

import Foundation

struct BoardFilter: Equatable {
    var searchText: String = ""
    var minimumPriority: Priority?
    var overdueOnly: Bool = false
    var owner: String?
    var tag: String?

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || minimumPriority != nil
            || overdueOnly
            || owner != nil
            || tag != nil
    }

    func matches(_ item: WorkItem) -> Bool {
        guard item.matches(searchText) else { return false }
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
