import Foundation

/// The contents of `~/Library/Application Support/WorkflowHost/config.json`.
///
/// Immutable and `Sendable`: every subsystem gets its own copy. Reloading builds
/// a new value rather than mutating this one.
public struct HostConfig: Codable, Sendable, Equatable {
    public let maxConcurrentPerRepo: Int
    public let pollIntervalSec: Int
    public let repos: [RepoConfig]

    public init(maxConcurrentPerRepo: Int, pollIntervalSec: Int, repos: [RepoConfig]) {
        self.maxConcurrentPerRepo = maxConcurrentPerRepo
        self.pollIntervalSec = pollIntervalSec
        self.repos = repos
    }
}

/// One repository the host watches, and the board columns it moves cards between.
public struct RepoConfig: Codable, Sendable, Equatable, Identifiable {
    public let owner: String
    public let name: String
    /// Absolute path to the local clone. Worktrees are created next to it.
    public let path: String
    /// The GitHub Projects v2 project number, as it appears in the project URL.
    public let projectNumber: Int
    public let readyColumn: String
    public let activeColumn: String
    public let reviewColumn: String

    /// `owner/name`, the form used in log lines and as the `runs.repo` value.
    public var id: String { "\(owner)/\(name)" }

    public init(
        owner: String,
        name: String,
        path: String,
        projectNumber: Int,
        readyColumn: String,
        activeColumn: String,
        reviewColumn: String
    ) {
        self.owner = owner
        self.name = name
        self.path = path
        self.projectNumber = projectNumber
        self.readyColumn = readyColumn
        self.activeColumn = activeColumn
        self.reviewColumn = reviewColumn
    }
}
