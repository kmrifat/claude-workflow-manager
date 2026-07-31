import Foundation

/// One dispatched run. Mirrors the `runs` table exactly.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    /// `owner/name`.
    public let repo: String
    public let issueNumber: Int
    /// `api`, `ui`, `db`, `infra` — the area lock that keeps two runs out of the
    /// same module.
    public let area: String?
    public let branch: String?
    public let worktreePath: String?
    /// Claude Remote Control session, deep-linked to rather than proxied.
    public let sessionId: String?
    public let pid: Int32?
    public let status: RunStatus
    public let startedAt: Date?
    public let endedAt: Date?
    public let exitCode: Int32?

    public init(
        id: Int64,
        repo: String,
        issueNumber: Int,
        area: String? = nil,
        branch: String? = nil,
        worktreePath: String? = nil,
        sessionId: String? = nil,
        pid: Int32? = nil,
        status: RunStatus,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.repo = repo
        self.issueNumber = issueNumber
        self.area = area
        self.branch = branch
        self.worktreePath = worktreePath
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
    }

    public var isLive: Bool { status == .running || status == .queued }

    /// Deep link into the Claude app. We store the session id and link to it —
    /// the session's own output is never rendered or proxied here.
    public var sessionURL: URL? {
        sessionId.flatMap { URL(string: "claude://session/\($0)") }
    }
}

/// What happened, and when. Mirrors the `events` table.
public struct EventRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let runId: Int64?
    public let at: Date
    public let kind: EventKind
    public let detail: String?

    public init(id: Int64, runId: Int64?, at: Date, kind: EventKind, detail: String?) {
        self.id = id
        self.runId = runId
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case dispatched
    case commit
    case prOpened = "pr_opened"
    case blocked
    case failed
    case stopped

    /// Only these two are worth interrupting someone for. A notification per
    /// commit would recreate the problem this app exists to solve.
    public var isNotifiable: Bool { self == .prOpened || self == .failed }

    public var title: String {
        switch self {
        case .dispatched: "Dispatched"
        case .commit: "Commit"
        case .prOpened: "PR opened"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}
