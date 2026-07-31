import Foundation

/// What one poll tick did, per repo. Printed by `WorkflowHost poll --once` and,
/// from phase 3, surfaced on the dashboard as "host last seen".
public struct PollReport: Sendable {
    public struct RepoOutcome: Sendable {
        public enum Result: Sendable {
            case updated(issues: Int, pullRequests: Int, boardItems: Int)
            /// Every collection answered 304 — nothing changed since last tick.
            case unchanged
            case failed(String)
        }

        public let repo: String
        public let result: Result

        public var isFailure: Bool {
            if case .failed = result { return true }
            return false
        }

        public var line: String {
            switch result {
            case .updated(let issues, let pullRequests, let boardItems):
                return "\(repo)  \(issues) issue\(issues == 1 ? "" : "s"), "
                    + "\(pullRequests) PR\(pullRequests == 1 ? "" : "s"), \(boardItems) card\(boardItems == 1 ? "" : "s")"
            case .unchanged:
                return "\(repo)  unchanged"
            case .failed(let reason):
                return "\(repo)  FAILED — \(reason)"
            }
        }
    }

    public let startedAt: Date
    public let outcomes: [RepoOutcome]
    /// Set when the tick stopped early because the request budget ran out.
    public let backoffUntil: Date?

    public var hadFailures: Bool { outcomes.contains(where: \.isFailure) }

    public var summary: String {
        var lines = outcomes.map { "  " + $0.line }
        if let backoffUntil {
            lines.append("  rate limited — next attempt after \(backoffUntil.formatted(.iso8601))")
        }
        return lines.joined(separator: "\n")
    }
}
