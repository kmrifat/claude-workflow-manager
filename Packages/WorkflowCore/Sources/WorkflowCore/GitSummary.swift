import Foundation

/// What sits on a run's branch. Shared with both clients.
public struct GitSummary: Codable, Sendable, Equatable {
    public let branch: String
    /// Never assumed to be `main` — read from what GitHub reports.
    public let baseBranch: String
    public let commits: [Commit]
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int

    public var commitCount: Int { commits.count }
    public var lastCommitAt: Date? { commits.first?.date }
    /// A branch created but not yet committed to — a real state, since the
    /// worktree exists before the first commit lands.
    public var isEmpty: Bool { commits.isEmpty }

    public init(
        branch: String,
        baseBranch: String,
        commits: [Commit],
        filesChanged: Int,
        insertions: Int,
        deletions: Int
    ) {
        self.branch = branch
        self.baseBranch = baseBranch
        self.commits = commits
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }

    public struct Commit: Codable, Sendable, Equatable, Identifiable {
        public let sha: String
        public let subject: String
        public let date: Date

        public var id: String { sha }

        public init(sha: String, subject: String, date: Date) {
            self.sha = sha
            self.subject = subject
            self.date = date
        }
    }
}
