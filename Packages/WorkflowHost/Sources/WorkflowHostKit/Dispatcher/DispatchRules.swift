import Foundation
import WorkflowCore

/// Which issue, if any, runs next.
///
/// Pure functions over values — no I/O, no clock, no GitHub. Every rule here is
/// a reason *not* to dispatch something, and each one exists because breaking it
/// causes a specific, known problem.
public enum DispatchRules {
    /// Why an issue was passed over. Surfaced so the dashboard can say why the
    /// queue is idle rather than just showing nothing happening.
    public enum Skip: Equatable, Sendable {
        case atConcurrencyLimit(active: Int, limit: Int)
        case claimed(by: [String])
        case blocked(by: [Int])
        case areaBusy(String)
        case notAnIssue
    }

    public struct Decision: Equatable, Sendable {
        public let selected: ReadyIssue?
        /// Every candidate considered, and why it was passed over.
        public let skipped: [(issue: Int, reason: Skip)]

        public static func == (lhs: Decision, rhs: Decision) -> Bool {
            lhs.selected == rhs.selected
                && lhs.skipped.count == rhs.skipped.count
                && zip(lhs.skipped, rhs.skipped).allSatisfy { $0.issue == $1.issue && $0.reason == $1.reason }
        }
    }

    /// Takes ready issues in board order and returns the first that survives
    /// every rule.
    ///
    /// Order matters: the concurrency check short-circuits before anything else,
    /// because at the limit no issue is dispatchable and reporting per-issue
    /// reasons would be noise.
    public static func selectNext(
        ready: [ReadyIssue],
        activeRuns: [RunRecord],
        maxConcurrentPerRepo: Int
    ) -> Decision {
        guard activeRuns.count < maxConcurrentPerRepo else {
            return Decision(
                selected: nil,
                skipped: [(0, .atConcurrencyLimit(active: activeRuns.count, limit: maxConcurrentPerRepo))]
            )
        }

        // Worktrees isolate files, not meaning. Two runs touching the same area
        // produce conflicting PRs that both look fine in isolation. Don't remove
        // this for speed.
        let busyAreas = Set(activeRuns.compactMap(\.area))
        // A run already exists for this issue — usually a leftover from a
        // previous tick that has not finished.
        let claimedIssues = Set(activeRuns.map(\.issueNumber))

        var skipped: [(Int, Skip)] = []

        for issue in ready {
            // Assignment is the cross-machine lock. Another host claims an issue
            // by assigning it before dispatching, so anything assigned is
            // someone else's — including our own earlier dispatch.
            if issue.isClaimed {
                skipped.append((issue.number, .claimed(by: issue.assignees)))
                continue
            }
            if claimedIssues.contains(issue.number) {
                skipped.append((issue.number, .claimed(by: ["this host"])))
                continue
            }
            if issue.isBlocked {
                skipped.append((issue.number, .blocked(by: issue.blockedBy)))
                continue
            }
            if let area = issue.area, busyAreas.contains(area) {
                skipped.append((issue.number, .areaBusy(area)))
                continue
            }
            return Decision(selected: issue, skipped: skipped)
        }

        return Decision(selected: nil, skipped: skipped)
    }

    /// The branch a run gets. Matches what `IssueBranchMatcher` looks for.
    public static func branchName(forIssue number: Int) -> String {
        "issue-\(number)"
    }

    /// Worktrees live beside the clone, not inside it — a worktree inside the
    /// repository would show up as untracked content in every status.
    public static func worktreePath(repoPath: String, issue: Int) -> String {
        let repo = URL(filePath: repoPath, directoryHint: .isDirectory)
            .standardizedFileURL
        let name = repo.lastPathComponent
        return repo
            .deletingLastPathComponent()
            .appending(path: "\(name)-issue-\(issue)")
            .path(percentEncoded: false)
    }
}
