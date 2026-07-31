import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("CacheStore")
struct CacheStoreTests {
    @Test("values round-trip with their ETag and timestamp")
    func roundTrip() throws {
        let fixture = try Fixture()
        let cache = fixture.cache
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let issues = [GitHubIssue(
            number: 7, title: "Add API", url: URL(string: "https://x/7")!, state: "open",
            labels: ["api"], assignees: [], body: nil,
            updatedAt: Date(timeIntervalSince1970: 1_699_999_000)
        )]
        try cache.write("issues:me/a", value: issues, etag: "\"abc\"", at: fetchedAt)

        let entry = try #require(try cache.read("issues:me/a", as: [GitHubIssue].self))
        #expect(entry.value == issues)
        // The ETag rides inside the value JSON so it survives a restart without
        // needing an extra column — the cache table stays generic.
        #expect(entry.etag == "\"abc\"")
        #expect(entry.fetchedAt == fetchedAt)
    }

    @Test("writing the same key twice updates rather than duplicating")
    func upserts() throws {
        let fixture = try Fixture()
        let cache = fixture.cache

        try cache.write("k", value: [1, 2], etag: nil, at: Date(timeIntervalSince1970: 1))
        try cache.write("k", value: [3], etag: nil, at: Date(timeIntervalSince1970: 2))

        let entry = try #require(try cache.read("k", as: [Int].self))
        #expect(entry.value == [3])
        #expect(entry.fetchedAt == Date(timeIntervalSince1970: 2))
    }

    @Test("touch refreshes the timestamp without rewriting the payload")
    func touch() throws {
        let fixture = try Fixture()
        let cache = fixture.cache

        try cache.write("k", value: [1], etag: "\"e\"", at: Date(timeIntervalSince1970: 1))
        try cache.touch("k", at: Date(timeIntervalSince1970: 500))

        let entry = try #require(try cache.read("k", as: [Int].self))
        #expect(entry.value == [1])
        #expect(entry.etag == "\"e\"")
        #expect(entry.fetchedAt == Date(timeIntervalSince1970: 500))
    }

    @Test("a missing key reads as nil, not an error")
    func missingKey() throws {
        let fixture = try Fixture()
        let cache = fixture.cache
        #expect(try cache.read("absent", as: [Int].self) == nil)
    }
}

@Suite("GitHubPoller")
struct GitHubPollerTests {
    private func makeConfig(_ fixture: Fixture, repos: Int = 1) throws -> HostConfig {
        fixture.config(repos: try (0..<repos).map { try fixture.repo("product-\($0)") })
    }

    /// Replies to the four calls a tick makes: repo, issues, pulls, board.
    private func happyTransport() -> StubTransport {
        StubTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/graphql") {
                return .init(body: boardJSON, headers: healthyRateLimitHeaders())
            }
            if path.hasSuffix("/issues") {
                return .init(body: """
                    [{ "number": 7, "title": "Add API", "state": "open",
                       "html_url": "https://github.com/me/product-0/issues/7",
                       "updated_at": "2026-07-30T12:00:00Z", "body": null,
                       "labels": [], "assignees": [] }]
                    """, headers: healthyRateLimitHeaders())
            }
            if path.hasSuffix("/pulls") {
                return .init(body: "[]", headers: healthyRateLimitHeaders())
            }
            return .init(body: #"{"default_branch": "main"}"#, headers: healthyRateLimitHeaders())
        }
    }

    @Test("a tick writes issues, pulls, repo metadata and the board into the cache")
    func populatesCache() async throws {
        let fixture = try Fixture()
        let config = try makeConfig(fixture)
        let cache = fixture.cache

        let poller = GitHubPoller(
            config: config,
            client: GitHubClient(token: "t", transport: happyTransport()),
            cache: cache
        )
        let report = await poller.pollOnce()

        #expect(!report.hadFailures)
        let repo = config.repos[0]
        #expect(try cache.read(CacheStore.Key.issues(repo), as: [GitHubIssue].self)?.value.count == 1)
        #expect(try cache.read(CacheStore.Key.pullRequests(repo), as: [GitHubPullRequest].self)?.value.isEmpty == true)
        #expect(try cache.read(CacheStore.Key.repository(repo), as: RepositoryInfo.self)?.value.defaultBranch == "main")

        let board = try #require(try cache.read(CacheStore.Key.project(repo), as: ProjectSnapshot.self))
        #expect(board.value.items(inColumn: "Ready").map { $0.content?.number } == [7])
    }

    @Test("a 304 keeps the cached payload and only refreshes its timestamp")
    func conditionalTickReusesCache() async throws {
        let fixture = try Fixture()
        let config = try makeConfig(fixture)
        let cache = fixture.cache

        let sawIfNoneMatch = Mutex(false)
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/graphql") {
                return .init(body: boardJSON, headers: healthyRateLimitHeaders())
            }
            if path.hasSuffix("/issues") {
                if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                    sawIfNoneMatch.withLock { $0 = true }
                    return .init(status: 304, body: "", headers: healthyRateLimitHeaders())
                }
                return .init(body: """
                    [{ "number": 7, "title": "Add API", "state": "open",
                       "html_url": "https://x/7", "updated_at": "2026-07-30T12:00:00Z",
                       "body": null, "labels": [], "assignees": [] }]
                    """, headers: healthyRateLimitHeaders().merging(["etag": "\"v1\""]) { _, n in n })
            }
            if path.hasSuffix("/pulls") { return .init(body: "[]", headers: healthyRateLimitHeaders()) }
            return .init(body: #"{"default_branch": "main"}"#, headers: healthyRateLimitHeaders())
        }

        let poller = GitHubPoller(
            config: config, client: GitHubClient(token: "t", transport: transport), cache: cache
        )
        await poller.pollOnce()
        let afterFirst = try #require(try cache.read(CacheStore.Key.issues(config.repos[0]), as: [GitHubIssue].self))
        #expect(afterFirst.etag == "\"v1\"")

        await poller.pollOnce()

        #expect(sawIfNoneMatch.withLock { $0 })
        let afterSecond = try #require(try cache.read(CacheStore.Key.issues(config.repos[0]), as: [GitHubIssue].self))
        // The payload survived the 304 rather than being blanked.
        #expect(afterSecond.value.count == 1)
        #expect(afterSecond.fetchedAt >= afterFirst.fetchedAt)
    }

    @Test("one failing repo does not stop the others")
    func failureIsIsolated() async throws {
        let fixture = try Fixture()
        let config = try makeConfig(fixture, repos: 2)
        let cache = fixture.cache

        let transport = StubTransport { request, _ in
            let url = request.url?.absoluteString ?? ""
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if url.contains("product-0") || body.contains("product-0") {
                return .init(status: 500, body: #"{"message": "boom"}"#)
            }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/graphql") { return .init(body: boardJSON, headers: healthyRateLimitHeaders()) }
            if path.hasSuffix("/issues") || path.hasSuffix("/pulls") {
                return .init(body: "[]", headers: healthyRateLimitHeaders())
            }
            return .init(body: #"{"default_branch": "main"}"#, headers: healthyRateLimitHeaders())
        }

        let poller = GitHubPoller(
            config: config, client: GitHubClient(token: "t", transport: transport), cache: cache
        )
        let report = await poller.pollOnce()

        #expect(report.outcomes.count == 2)
        #expect(report.outcomes[0].isFailure)
        #expect(!report.outcomes[1].isFailure)
        // The healthy repo still landed in the cache.
        #expect(try cache.read(CacheStore.Key.project(config.repos[1]), as: ProjectSnapshot.self) != nil)
    }

    @Test("a rate limit sets a backoff deadline and skips the remaining repos")
    func rateLimitBacksOff() async throws {
        let fixture = try Fixture()
        let config = try makeConfig(fixture, repos: 2)

        let reset = Date().addingTimeInterval(600)
        let transport = StubTransport { _, _ in
            .init(status: 403, body: #"{"message": "rate limit"}"#, headers: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ])
        }

        let poller = GitHubPoller(
            config: config,
            client: GitHubClient(token: "t", transport: transport),
            cache: fixture.cache
        )
        let report = await poller.pollOnce()

        let backoff = try #require(report.backoffUntil)
        #expect(abs(backoff.timeIntervalSince(reset)) < 1)
        // The second repo was skipped rather than burning another failure.
        #expect(report.outcomes[1].line.contains("skipped, rate limited"))
        // Two repos, but only the first one's requests were attempted.
        #expect(transport.requests.count == 1)
    }

    @Test("nearly-exhausted budget backs off before being locked out")
    func proactiveBackoff() async throws {
        let fixture = try Fixture()
        let config = try makeConfig(fixture)

        let reset = Date().addingTimeInterval(300)
        let transport = StubTransport { request, _ in
            let headers = [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "2",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ]
            let path = request.url?.path ?? ""
            if path.hasSuffix("/graphql") { return .init(body: boardJSON, headers: headers) }
            if path.hasSuffix("/issues") || path.hasSuffix("/pulls") {
                return .init(body: "[]", headers: headers)
            }
            return .init(body: #"{"default_branch": "main"}"#, headers: headers)
        }

        let poller = GitHubPoller(
            config: config,
            client: GitHubClient(token: "t", transport: transport),
            cache: fixture.cache
        )
        let report = await poller.pollOnce()

        #expect(!report.hadFailures)
        let backoff = try #require(report.backoffUntil)
        #expect(abs(backoff.timeIntervalSince(reset)) < 1)
    }
}
