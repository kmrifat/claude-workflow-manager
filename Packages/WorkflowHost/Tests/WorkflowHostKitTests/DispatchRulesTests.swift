import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("Dispatch rules")
struct DispatchRulesTests {
    private func issue(
        _ number: Int,
        area: String? = nil,
        assignees: [String] = [],
        blockedBy: [Int] = []
    ) -> ReadyIssue {
        ReadyIssue(
            number: number,
            title: "Issue \(number)",
            url: URL(string: "https://github.com/me/a/issues/\(number)")!,
            area: area,
            assignees: assignees,
            blockedBy: blockedBy
        )
    }

    private func run(_ id: Int64, issue: Int, area: String? = nil) -> RunRecord {
        RunRecord(id: id, repo: "me/a", issueNumber: issue, area: area, status: .running)
    }

    @Test("takes the first ready issue in board order")
    func picksBoardOrder() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7), issue(9)], activeRuns: [], maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 7)
        #expect(decision.skipped.isEmpty)
    }

    @Test("dispatches nothing at the concurrency limit")
    func respectsConcurrency() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7)],
            activeRuns: [run(1, issue: 3), run(2, issue: 4)],
            maxConcurrentPerRepo: 2
        )
        #expect(decision.selected == nil)
        // Short-circuits before per-issue reasons, which would be noise.
        #expect(decision.skipped.first?.reason == .atConcurrencyLimit(active: 2, limit: 2))
    }

    /// Issue assignment is the cross-machine lock. Two hosts share no state, so
    /// anything already claimed belongs to someone else.
    @Test("skips an issue assigned to anyone")
    func skipsClaimed() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7, assignees: ["someone-else"]), issue(9)],
            activeRuns: [], maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 9)
        #expect(decision.skipped.first?.reason == .claimed(by: ["someone-else"]))
    }

    @Test("skips an issue this host is already running")
    func skipsOwnInFlightIssue() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7), issue(9)],
            activeRuns: [run(1, issue: 7)],
            maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 9)
    }

    @Test("skips an issue blocked by an open issue")
    func skipsBlocked() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7, blockedBy: [3]), issue(9)],
            activeRuns: [], maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 9)
        #expect(decision.skipped.first?.reason == .blocked(by: [3]))
    }

    /// Worktrees isolate files, not meaning. Two runs in the same area produce
    /// conflicting PRs that each look fine alone.
    @Test("skips an issue whose area is already busy")
    func skipsBusyArea() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7, area: "api"), issue(9, area: "ui")],
            activeRuns: [run(1, issue: 3, area: "api")],
            maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 9)
        #expect(decision.skipped.first?.reason == .areaBusy("api"))
    }

    @Test("an issue with no area is never area-blocked")
    func noAreaIsNeverBlocked() {
        let decision = DispatchRules.selectNext(
            ready: [issue(7)],
            activeRuns: [run(1, issue: 3, area: "api")],
            maxConcurrentPerRepo: 2
        )
        #expect(decision.selected?.number == 7)
    }

    @Test("reports every reason when nothing is dispatchable")
    func reportsWhyIdle() {
        let decision = DispatchRules.selectNext(
            ready: [
                issue(7, assignees: ["a"]),
                issue(8, blockedBy: [1]),
                issue(9, area: "api"),
            ],
            activeRuns: [run(1, issue: 3, area: "api")],
            maxConcurrentPerRepo: 2
        )
        #expect(decision.selected == nil)
        #expect(decision.skipped.map(\.reason) == [
            .claimed(by: ["a"]), .blocked(by: [1]), .areaBusy("api"),
        ])
    }

    @Test("branch and worktree names follow the documented convention")
    func names() {
        // `issue-<n>` is a contract with the kanban app's IssueBranchMatcher,
        // which lives in a separate module and looks for exactly this shape. If
        // this changes, branch progress silently stops appearing on the board.
        #expect(DispatchRules.branchName(forIssue: 7) == "issue-7")

        let worktree = DispatchRules.worktreePath(repoPath: "/Users/me/code/product-a", issue: 7)
        // Beside the clone, never inside it — a worktree within the repository
        // shows up as untracked content in every status.
        #expect(worktree == "/Users/me/code/product-a-issue-7")
        #expect(!worktree.hasPrefix("/Users/me/code/product-a/"))
    }

    @Test("a trailing slash on the repo path does not change the worktree name")
    func worktreePathNormalises() {
        #expect(
            DispatchRules.worktreePath(repoPath: "/Users/me/code/product-a/", issue: 7)
                == "/Users/me/code/product-a-issue-7"
        )
    }
}

@Suite("blocked-by parsing")
struct BlockedByTests {
    @Test("finds an open blocker")
    func findsOpenBlocker() {
        #expect(StateBuilder.blockedBy("blocked-by #28", openNumbers: [28]) == [28])
    }

    /// A closed blocker is not a blocker; checking only the text would stall the
    /// queue forever on work that is already done.
    @Test("ignores a closed blocker")
    func ignoresClosedBlocker() {
        #expect(StateBuilder.blockedBy("blocked-by #28", openNumbers: [99]) == [])
    }

    @Test("finds several, one per line")
    func findsSeveral() {
        let body = "blocked-by #1\nsome prose\nblocked-by #2"
        #expect(StateBuilder.blockedBy(body, openNumbers: [1, 2, 3]) == [1, 2])
    }

    @Test("is case-insensitive and ignores unrelated hashes")
    func caseAndNoise() {
        #expect(StateBuilder.blockedBy("Blocked-By #5", openNumbers: [5]) == [5])
        #expect(StateBuilder.blockedBy("see #5 for context", openNumbers: [5]) == [])
        #expect(StateBuilder.blockedBy(nil, openNumbers: [5]) == [])
        #expect(StateBuilder.blockedBy("blocked-by nothing", openNumbers: [5]) == [])
    }
}

@Suite("Run store")
struct RunStoreTests {
    @Test("creating a run also records that it was dispatched")
    func createRecordsEvent() throws {
        let fixture = try Fixture()
        let store = RunStore(database: fixture.database)

        let id = try store.createRun(
            repo: "me/a", issueNumber: 7, area: "api",
            branch: "issue-7", worktreePath: "/tmp/a-issue-7"
        )

        let run = try #require(try store.run(id: id))
        #expect(run.status == .running)
        #expect(run.branch == "issue-7")
        #expect(run.area == "api")
        // A run with no record of having started is a lie the dashboard shows.
        #expect(try store.events(runId: id).map(\.kind) == [.dispatched])
    }

    @Test("finishing sets the terminal state and its event together")
    func finishIsAtomic() throws {
        let fixture = try Fixture()
        let store = RunStore(database: fixture.database)
        let id = try store.createRun(
            repo: "me/a", issueNumber: 7, area: nil, branch: "issue-7", worktreePath: nil
        )

        try store.finish(
            runId: id, status: .review, exitCode: 0,
            event: .prOpened, detail: "https://github.com/me/a/pull/12"
        )

        let run = try #require(try store.run(id: id))
        #expect(run.status == .review)
        #expect(run.endedAt != nil)
        #expect(try store.events(runId: id).map(\.kind) == [.prOpened, .dispatched])
    }

    @Test("only queued and running runs occupy a slot")
    func activeExcludesFinished() throws {
        let fixture = try Fixture()
        let store = RunStore(database: fixture.database)

        let live = try store.createRun(repo: "me/a", issueNumber: 1, area: nil, branch: nil, worktreePath: nil)
        let done = try store.createRun(repo: "me/a", issueNumber: 2, area: nil, branch: nil, worktreePath: nil)
        try store.finish(runId: done, status: .review, exitCode: 0, event: .prOpened, detail: nil)

        #expect(try store.activeRuns(repo: "me/a").map(\.id) == [live])
        #expect(try store.activeRuns(repo: "other/repo").isEmpty)
    }

    @Test("events come back newest first")
    func eventOrder() throws {
        let fixture = try Fixture()
        let store = RunStore(database: fixture.database)

        try store.recordEvent(runId: nil, kind: .blocked, detail: "first",
                              at: Date(timeIntervalSince1970: 1_000))
        try store.recordEvent(runId: nil, kind: .failed, detail: "second",
                              at: Date(timeIntervalSince1970: 2_000))

        #expect(try store.recentEvents().map(\.detail) == ["second", "first"])
    }

    @Test("pr_opened and failed are the only notifiable events")
    func notifiableEvents() {
        // A notification per commit recreates exactly the problem this exists
        // to solve.
        #expect(EventKind.allCases.filter(\.isNotifiable) == [.prOpened, .failed])
        #expect(EventKind.prOpened.rawValue == "pr_opened")
    }
}
