import Foundation
import WorkflowCore

/// Assembles `DashboardState` from the cache and the run history.
///
/// Nothing here is stored. Board columns, issues and PR state come from the
/// cache the poller wrote; runs and events come from SQLite. If our idea of a
/// card's column ever disagrees with GitHub's, GitHub wins — this only ever
/// reads what the poller last saw.
public struct StateBuilder: Sendable {
    private let config: HostConfig
    private let cache: CacheStore
    private let runs: RunStore
    private let git: GitReader

    public init(config: HostConfig, cache: CacheStore, runs: RunStore, git: GitReader) {
        self.config = config
        self.cache = cache
        self.runs = runs
        self.git = git
    }

    public func build(now: Date = Date()) async -> DashboardState {
        var repoStates: [RepoState] = []

        for repo in config.repos {
            let issues = (try? cache.read(CacheStore.Key.issues(repo), as: [GitHubIssue].self))?.value ?? []
            let board = try? cache.read(CacheStore.Key.project(repo), as: ProjectSnapshot.self)
            let polledAt = board?.fetchedAt ?? (try? cache.fetchedAt(CacheStore.Key.issues(repo))) ?? nil

            let ready = readyIssues(repo: repo, board: board?.value, issues: issues)
            let active = await activeRuns(repo: repo, issues: issues)

            repoStates.append(RepoState(
                id: repo.id,
                readyIssues: ready,
                activeRuns: active,
                lastPolledAt: polledAt,
                maxConcurrent: config.maxConcurrentPerRepo
            ))
        }

        return DashboardState(
            hostVersion: HostBoot.version,
            generatedAt: now,
            repos: repoStates,
            recentEvents: (try? runs.recentEvents(limit: 100)) ?? []
        )
    }

    public func runDetail(id: Int64) async -> RunDetail? {
        guard let run = (try? runs.run(id: id)) ?? nil else { return nil }

        let repo = config.repos.first { $0.id == run.repo }
        let issues = repo.flatMap {
            (try? cache.read(CacheStore.Key.issues($0), as: [GitHubIssue].self))?.value
        } ?? []

        return RunDetail(
            run: run,
            issueTitle: issues.first { $0.number == run.issueNumber }?.title,
            git: await summary(for: run, repo: repo),
            events: (try? runs.events(runId: id)) ?? []
        )
    }

    // MARK: - Pieces

    /// Board order, decorated with what would stop each issue being dispatched.
    func readyIssues(
        repo: RepoConfig,
        board: ProjectSnapshot?,
        issues: [GitHubIssue]
    ) -> [ReadyIssue] {
        let byNumber = Dictionary(issues.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let openNumbers = Set(issues.filter { $0.state.lowercased() == "open" }.map(\.number))

        guard let board else { return [] }

        return board.items(inColumn: repo.readyColumn).compactMap { item in
            guard let content = item.content, content.kind == .issue else { return nil }
            let issue = byNumber[content.number]

            return ReadyIssue(
                number: content.number,
                title: content.title,
                url: content.url,
                area: issue.flatMap(Self.area(of:)),
                // The board carries assignees too, but the issue payload is
                // fresher when both are present.
                assignees: issue?.assignees ?? content.assignees,
                blockedBy: Self.blockedBy(issue?.body, openNumbers: openNumbers)
            )
        }
    }

    private func activeRuns(repo: RepoConfig, issues: [GitHubIssue]) async -> [RunView] {
        let records = (try? runs.activeRuns(repo: repo.id)) ?? []
        var views: [RunView] = []
        for record in records {
            views.append(RunView(
                run: record,
                issueTitle: issues.first { $0.number == record.issueNumber }?.title,
                git: await summary(for: record, repo: repo)
            ))
        }
        return views
    }

    private func summary(for run: RunRecord, repo: RepoConfig?) async -> GitSummary? {
        guard let repo, let branch = run.branch else { return nil }
        let base = (try? cache.read(CacheStore.Key.repository(repo), as: RepositoryInfo.self))?
            .value.defaultBranch ?? "main"
        // A run whose branch was never pushed, or whose worktree is gone, must
        // not take the whole dashboard down with it.
        return try? await git.summary(repo: repo, branch: branch, base: base)
    }

    /// The `area` label, from the fixed vocabulary the area lock uses.
    static func area(of issue: GitHubIssue) -> String? {
        let areas: Set<String> = ["api", "ui", "db", "infra"]
        return issue.labels.first { areas.contains($0.lowercased()) }?.lowercased()
    }

    /// Issue numbers named by `blocked-by #N` in the body that are still open.
    ///
    /// A closed blocker is not a blocker, so the check is against the open set
    /// rather than merely against the text.
    static func blockedBy(_ body: String?, openNumbers: Set<Int>) -> [Int] {
        guard let body else { return [] }
        var found: [Int] = []
        let lowered = body.lowercased()
        var searchRange = lowered.startIndex..<lowered.endIndex

        while let match = lowered.range(of: "blocked-by", range: searchRange) {
            // Take the first #N after the marker, on the same line.
            let lineEnd = lowered[match.upperBound...].firstIndex(of: "\n") ?? lowered.endIndex
            let tail = lowered[match.upperBound..<lineEnd]
            if let hash = tail.firstIndex(of: "#") {
                let digits = tail[tail.index(after: hash)...].prefix { $0.isNumber }
                if let number = Int(digits), openNumbers.contains(number) {
                    found.append(number)
                }
            }
            searchRange = lineEnd..<lowered.endIndex
            if searchRange.isEmpty { break }
        }
        return found
    }
}
