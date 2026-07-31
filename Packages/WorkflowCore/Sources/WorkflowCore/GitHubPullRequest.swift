import Foundation

/// An open pull request, as cached from GitHub.
public struct GitHubPullRequest: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let title: String
    public let url: URL
    public let state: String
    public let isDraft: Bool
    /// The branch the PR is from — how a run's branch is matched to its PR.
    public let headRef: String
    public let baseRef: String
    public let updatedAt: Date

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        state: String,
        isDraft: Bool,
        headRef: String,
        baseRef: String,
        updatedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRef = headRef
        self.baseRef = baseRef
        self.updatedAt = updatedAt
    }
}
