import Foundation

/// A GitHub Projects v2 board, as cached.
///
/// The board's Status field has no REST equivalent, which is why the poller uses
/// GraphQL for this one thing. Column membership lives here and nowhere else —
/// if our idea of a card's column disagrees with GitHub's, GitHub wins.
public struct ProjectSnapshot: Codable, Sendable, Equatable {
    /// GraphQL node id of the project. Needed by the column-move mutation.
    public let projectId: String
    public let number: Int
    public let title: String
    /// The single-select field the board's columns come from. Absent if the
    /// project has no field named `Status`.
    public let statusField: ProjectStatusField?
    /// Items in board order.
    public let items: [ProjectItem]

    public init(
        projectId: String,
        number: Int,
        title: String,
        statusField: ProjectStatusField?,
        items: [ProjectItem]
    ) {
        self.projectId = projectId
        self.number = number
        self.title = title
        self.statusField = statusField
        self.items = items
    }

    /// Items sitting in the named column, in board order.
    public func items(inColumn column: String) -> [ProjectItem] {
        items.filter { $0.status == column }
    }
}

/// A single-select field and its options — the board's columns.
public struct ProjectStatusField: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let options: [ProjectStatusOption]

    public init(id: String, name: String, options: [ProjectStatusOption]) {
        self.id = id
        self.name = name
        self.options = options
    }

    public func option(named name: String) -> ProjectStatusOption? {
        options.first { $0.name == name }
    }
}

public struct ProjectStatusOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One card on the board.
public struct ProjectItem: Codable, Sendable, Equatable, Identifiable {
    /// GraphQL node id of the *project item*, not of the issue it points at.
    /// The column-move mutation needs this one.
    public let id: String
    /// The column name, or `nil` for a card with no status set.
    public let status: String?
    /// `nil` for a draft issue that has never been converted.
    public let content: ProjectItemContent?

    public init(id: String, status: String?, content: ProjectItemContent?) {
        self.id = id
        self.status = status
        self.content = content
    }
}

public struct ProjectItemContent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case issue
        case pullRequest
    }

    public let kind: Kind
    public let number: Int
    public let title: String
    public let url: URL
    public let state: String
    /// Assignee logins — the cross-machine lock, read straight off the board.
    public let assignees: [String]

    public init(
        kind: Kind,
        number: Int,
        title: String,
        url: URL,
        state: String,
        assignees: [String]
    ) {
        self.kind = kind
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.assignees = assignees
    }
}
