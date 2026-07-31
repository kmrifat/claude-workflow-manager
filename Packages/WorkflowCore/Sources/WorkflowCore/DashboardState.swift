import Foundation

/// Everything the dashboard shows, in one payload.
///
/// Assembled per request from the cache and the run history — never stored, so
/// deleting `db.sqlite` costs run history and nothing else.
public struct DashboardState: Codable, Sendable, Equatable {
    public let hostVersion: String
    /// When the host produced this. Renders as "host last seen", so a sleeping
    /// Mac reads as stale rather than as nothing happening.
    public let generatedAt: Date
    public let repos: [RepoState]
    public let recentEvents: [EventRecord]

    public init(
        hostVersion: String,
        generatedAt: Date,
        repos: [RepoState],
        recentEvents: [EventRecord]
    ) {
        self.hostVersion = hostVersion
        self.generatedAt = generatedAt
        self.repos = repos
        self.recentEvents = recentEvents
    }

    public var activeRunCount: Int {
        repos.reduce(0) { $0 + $1.activeRuns.count }
    }
}

public struct RepoState: Codable, Sendable, Equatable, Identifiable {
    /// `owner/name`.
    public let id: String
    public let readyIssues: [ReadyIssue]
    public let activeRuns: [RunView]
    /// Cache age, so staleness is visible instead of misleading.
    public let lastPolledAt: Date?
    public let maxConcurrent: Int

    public init(
        id: String,
        readyIssues: [ReadyIssue],
        activeRuns: [RunView],
        lastPolledAt: Date?,
        maxConcurrent: Int
    ) {
        self.id = id
        self.readyIssues = readyIssues
        self.activeRuns = activeRuns
        self.lastPolledAt = lastPolledAt
        self.maxConcurrent = maxConcurrent
    }

    public var hasCapacity: Bool { activeRuns.count < maxConcurrent }
}

/// An issue sitting in the Ready column, with just enough to decide about it.
public struct ReadyIssue: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let title: String
    public let url: URL
    public let area: String?
    public let assignees: [String]
    /// Set when the issue names an open `blocked-by #N`.
    public let blockedBy: [Int]

    public var id: Int { number }
    /// Assignment is the cross-machine lock: claimed by anyone means hands off.
    public var isClaimed: Bool { !assignees.isEmpty }
    public var isBlocked: Bool { !blockedBy.isEmpty }
    public var isDispatchable: Bool { !isClaimed && !isBlocked }

    public init(
        number: Int,
        title: String,
        url: URL,
        area: String?,
        assignees: [String],
        blockedBy: [Int]
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.area = area
        self.assignees = assignees
        self.blockedBy = blockedBy
    }
}

/// A run plus the things the table joins in: the issue's title, and what is on
/// its branch.
public struct RunView: Codable, Sendable, Equatable, Identifiable {
    public let run: RunRecord
    public let issueTitle: String?
    public let git: GitSummary?

    public var id: Int64 { run.id }

    public init(run: RunRecord, issueTitle: String?, git: GitSummary?) {
        self.run = run
        self.issueTitle = issueTitle
        self.git = git
    }
}

/// `GET /api/runs/:id`.
public struct RunDetail: Codable, Sendable, Equatable {
    public let run: RunRecord
    public let issueTitle: String?
    public let git: GitSummary?
    public let events: [EventRecord]

    public init(run: RunRecord, issueTitle: String?, git: GitSummary?, events: [EventRecord]) {
        self.run = run
        self.issueTitle = issueTitle
        self.git = git
        self.events = events
    }
}
