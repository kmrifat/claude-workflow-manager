import Foundation

/// An open issue, as cached from GitHub.
///
/// GitHub is the source of truth; this is a timestamped copy. The wire format's
/// quirks (snake_case, labels as objects) are translated in `WorkflowHostKit` so
/// they never reach the clients.
public struct GitHubIssue: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let title: String
    public let url: URL
    public let state: String
    /// Label names. The dispatcher reads `area` from these in phase 6.
    public let labels: [String]
    /// Assignee logins. Issue assignment is the cross-machine lock: a run claims
    /// an issue by assigning it, and other hosts skip anything already claimed.
    public let assignees: [String]
    /// Needed for `blocked-by #N` parsing in phase 6.
    public let body: String?
    public let updatedAt: Date

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        state: String,
        labels: [String],
        assignees: [String],
        body: String?,
        updatedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.body = body
        self.updatedAt = updatedAt
    }
}
