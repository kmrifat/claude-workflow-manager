import Foundation
import WorkflowCore

/// Polls GitHub on an interval and writes what it finds into the cache.
///
/// An actor because it owns mutable state that nothing else serializes: the
/// backoff deadline. The cache it writes through is *not* actor-isolated — GRDB
/// owns that (see the concurrency rule in CLAUDE.md).
///
/// The loop must never die. A repo that fails is logged and retried on the next
/// tick; the only thing that stops `run()` is cancellation.
public actor GitHubPoller {
    private let config: HostConfig
    private let client: GitHubClient
    private let cache: CacheStore
    /// Told when a tick changed something, so the dashboard can re-fetch. The
    /// poller only ever broadcasts — it never calls into another actor's state.
    private let hub: EventHub?

    /// Set when GitHub says the budget is spent. Until it passes, ticks are skipped.
    private var backoffUntil: Date?

    public init(config: HostConfig, client: GitHubClient, cache: CacheStore, hub: EventHub? = nil) {
        self.config = config
        self.client = client
        self.cache = cache
        self.hub = hub
    }

    /// Runs until cancelled.
    public func run() async {
        Log.poller.info("polling \(self.config.repos.count) repo(s) every \(self.config.pollIntervalSec)s")

        while !Task.isCancelled {
            if let until = backoffUntil, until > Date() {
                Log.poller.notice("backing off until \(until.formatted(.iso8601), privacy: .public)")
                guard await sleep(until: until) else { return }
                continue
            }

            let report = await pollOnce()
            for outcome in report.outcomes where outcome.isFailure {
                Log.poller.error("\(outcome.line, privacy: .public)")
            }

            guard await sleep(for: TimeInterval(config.pollIntervalSec)) else { return }
        }
    }

    /// One pass over every repo. Never throws — that is the whole point.
    @discardableResult
    public func pollOnce() async -> PollReport {
        let startedAt = Date()
        var outcomes: [PollReport.RepoOutcome] = []

        for repo in config.repos {
            if let until = backoffUntil, until > Date() {
                // The budget ran out partway through; leave the rest for the
                // next tick rather than burning failures against a closed door.
                outcomes.append(.init(repo: repo.id, result: .failed("skipped, rate limited")))
                continue
            }
            outcomes.append(await poll(repo))
        }

        let report = PollReport(startedAt: startedAt, outcomes: outcomes, backoffUntil: backoffUntil)
        // Only nudge when something actually moved; an unchanged tick would
        // otherwise wake every connected page for nothing.
        if outcomes.contains(where: { if case .updated = $0.result { return true }; return false }) {
            await hub?.broadcast()
        }
        return report
    }

    private func poll(_ repo: RepoConfig) async -> PollReport.RepoOutcome {
        do {
            let now = Date()

            let repository = try await client.repository(owner: repo.owner, name: repo.name)
            note(repository.rateLimit)
            try cache.write(
                CacheStore.Key.repository(repo),
                value: repository.value, etag: nil, at: now
            )

            let issueCount = try await refresh(
                key: CacheStore.Key.issues(repo),
                as: [GitHubIssue].self,
                at: now
            ) { etag in
                try await client.issues(owner: repo.owner, name: repo.name, ifNoneMatch: etag)
            }

            let pullCount = try await refresh(
                key: CacheStore.Key.pullRequests(repo),
                as: [GitHubPullRequest].self,
                at: now
            ) { etag in
                try await client.pullRequests(owner: repo.owner, name: repo.name, ifNoneMatch: etag)
            }

            // GraphQL has no conditional requests, so the board is fetched every
            // tick. It is also the only thing REST cannot give us.
            let board = try await client.projectSnapshot(
                owner: repo.owner, name: repo.name, number: repo.projectNumber
            )
            note(board.rateLimit)
            try cache.write(
                CacheStore.Key.project(repo),
                value: board.value, etag: nil, at: now
            )

            if issueCount == nil, pullCount == nil {
                return .init(repo: repo.id, result: .unchanged)
            }
            return .init(repo: repo.id, result: .updated(
                issues: issueCount ?? (try? cachedCount(CacheStore.Key.issues(repo), as: [GitHubIssue].self)) ?? 0,
                pullRequests: pullCount ?? (try? cachedCount(CacheStore.Key.pullRequests(repo), as: [GitHubPullRequest].self)) ?? 0,
                boardItems: board.value.items.count
            ))
        } catch let error as GitHubError {
            if case .rateLimited(let resetAt) = error {
                backoffUntil = resetAt
            }
            return .init(repo: repo.id, result: .failed(error.description))
        } catch {
            return .init(repo: repo.id, result: .failed(String(describing: error)))
        }
    }

    /// Conditional refresh: sends the cached ETag, and on a 304 just bumps
    /// `fetched_at` so staleness stays honest without rewriting the payload.
    ///
    /// Returns the new count, or `nil` when nothing changed.
    private func refresh<Value: Codable & Sendable>(
        key: String,
        as type: [Value].Type,
        at now: Date,
        fetch: (String?) async throws -> GitHubResponse<Conditional<[Value]>>
    ) async throws -> Int? {
        let cached = try cache.read(key, as: [Value].self)
        let response = try await fetch(cached?.etag)
        note(response.rateLimit)

        switch response.value {
        case .notModified:
            try cache.touch(key, at: now)
            return nil
        case .fetched(let values, let etag):
            try cache.write(key, value: values, etag: etag, at: now)
            return values.count
        }
    }

    private func cachedCount<Value: Codable & Sendable>(_ key: String, as type: [Value].Type) throws -> Int {
        try cache.read(key, as: [Value].self)?.value.count ?? 0
    }

    /// Backs off *before* being locked out. A tick costs several requests, so
    /// running the budget to exactly zero would strand a repo mid-pass.
    private func note(_ rateLimit: RateLimit?) {
        guard let rateLimit, rateLimit.isNearlyExhausted else { return }
        Log.poller.notice(
            "rate limit nearly exhausted (\(rateLimit.remaining)/\(rateLimit.limit))"
        )
        backoffUntil = rateLimit.resetAt
    }

    /// Returns false when cancelled, so callers can exit the loop cleanly.
    private func sleep(for seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }

    private func sleep(until deadline: Date) async -> Bool {
        await sleep(for: max(1, deadline.timeIntervalSinceNow))
    }
}
