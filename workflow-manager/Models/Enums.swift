//
//  Enums.swift
//  workflow-manager
//

import Foundation

/// Where a project sits in its lifecycle. Persisted as a raw string so that
/// `#Predicate` and `SortDescriptor` never have to reason about an enum type.
enum ProjectStatus: String, CaseIterable, Identifiable, Sendable {
    case planning
    case active
    case onHold
    case completed
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .planning:  "Planning"
        case .active:    "Active"
        case .onHold:    "On Hold"
        case .completed: "Completed"
        case .archived:  "Archived"
        }
    }

    var symbol: String {
        switch self {
        case .planning:  "pencil.and.outline"
        case .active:    "bolt.fill"
        case .onHold:    "pause.circle"
        case .completed: "checkmark.seal.fill"
        case .archived:  "archivebox"
        }
    }
}

enum Priority: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low:    "Low"
        case .normal: "Normal"
        case .high:   "High"
        case .urgent: "Urgent"
        }
    }

    var symbol: String {
        switch self {
        case .low:    "arrow.down"
        case .normal: "minus"
        case .high:   "arrow.up"
        case .urgent: "exclamationmark.2"
        }
    }

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Named accent for a project. The raw string is persisted; the `Color`
/// mapping lives in `Support/Palette.swift` so the models stay UI-free.
enum ProjectAccent: String, CaseIterable, Identifiable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

/// What a column means to the Claude sync, independent of what it is called.
///
/// Columns are user-renamable rows, so `.taskboard/tasks.json` cannot key its
/// four-value status vocabulary off a column's name — renaming "In Progress" to
/// "Doing" would break the contract silently. A role is the stable join: the
/// agent writes `in_progress`, and whichever column carries `.inProgress`
/// receives the card.
///
/// `nil` means the column takes part in no mapping. A project with no roles at
/// all cannot sync, and says so rather than doing nothing quietly.
enum ColumnRole: String, CaseIterable, Identifiable, Sendable {
    case todo
    case inProgress
    case review
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo:       "To Do"
        case .inProgress: "In Progress"
        case .review:     "In Review"
        case .done:       "Done"
        }
    }

    var status: WorkflowTasksFile.Status {
        switch self {
        case .todo:       .todo
        case .inProgress: .inProgress
        case .review:     .review
        case .done:       .done
        }
    }

    init(status: WorkflowTasksFile.Status) {
        switch status {
        case .todo:       self = .todo
        case .inProgress: self = .inProgress
        case .review:     self = .review
        case .done:       self = .done
        }
    }
}

enum BoardViewMode: String, CaseIterable, Identifiable, Sendable {
    case board
    case list
    case timeline
    /// Open GitHub issues for the project's linked repository. Read-only —
    /// GitHub owns these, we only mirror them.
    case issues
    /// Saved commands for the linked repository, plus ad-hoc ones.
    case terminal
    /// A read-only browse of the linked repository's working copy.
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board:    "Board"
        case .list:     "List"
        case .timeline: "Timeline"
        case .issues:   "Issues"
        case .terminal: "Terminal"
        case .files:    "Files"
        }
    }

    var symbol: String {
        switch self {
        case .board:    "rectangle.split.3x1"
        case .list:     "list.bullet"
        case .timeline: "chart.bar.xaxis"
        case .issues:   "arrow.triangle.branch"
        case .terminal: "terminal"
        case .files:    "folder"
        }
    }

    /// Modes that are meaningless without a linked working copy, and that show
    /// a "link a repository" placeholder instead of empty chrome.
    var requiresRepository: Bool {
        switch self {
        case .issues, .terminal, .files: true
        case .board, .list, .timeline:   false
        }
    }
}
