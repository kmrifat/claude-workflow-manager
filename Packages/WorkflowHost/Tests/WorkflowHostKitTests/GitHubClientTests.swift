import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("GitHubClient / REST")
struct GitHubClientRESTTests {
    private func issueJSON(
        number: Int,
        title: String = "An issue",
        isPullRequest: Bool = false,
        assignees: [String] = [],
        labels: [String] = []
    ) -> String {
        let marker = isPullRequest ? #", "pull_request": { "url": "https://x" }"# : ""
        return """
            {
              "number": \(number), "title": "\(title)", "state": "open",
              "html_url": "https://github.com/me/product-a/issues/\(number)",
              "updated_at": "2026-07-30T12:00:00Z",
              "body": "blocked-by #1",
              "labels": [\(labels.map { #"{"name": "\#($0)"}"# }.joined(separator: ","))],
              "assignees": [\(assignees.map { #"{"login": "\#($0)"}"# }.joined(separator: ","))]
              \(marker)
            }
            """
    }

    @Test("pull requests are filtered out of the issues endpoint")
    func filtersPullRequestsFromIssues() async throws {
        let transport = StubTransport(replies: [
            .init(
                body: "[\(issueJSON(number: 1)), \(issueJSON(number: 2, isPullRequest: true))]",
                headers: healthyRateLimitHeaders()
            )
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.issues(owner: "me", name: "product-a")
        guard case .fetched(let issues, _) = response.value else {
            Issue.record("expected .fetched")
            return
        }
        // GitHub's issues endpoint returns PRs too; treating them as issues would
        // make the dispatcher try to work on a pull request.
        #expect(issues.map(\.number) == [1])
    }

    @Test("issue fields the dispatcher depends on survive the round trip")
    func decodesIssueDetail() async throws {
        let transport = StubTransport(replies: [
            .init(
                body: "[\(issueJSON(number: 7, title: "Add API", assignees: ["kmrifat"], labels: ["api", "bug"]))]",
                headers: healthyRateLimitHeaders()
            )
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.issues(owner: "me", name: "product-a")
        guard case .fetched(let issues, _) = response.value, let issue = issues.first else {
            Issue.record("expected one issue")
            return
        }
        #expect(issue.number == 7)
        #expect(issue.title == "Add API")
        #expect(issue.labels == ["api", "bug"])          // area lock, phase 6
        #expect(issue.assignees == ["kmrifat"])          // cross-machine lock
        #expect(issue.body == "blocked-by #1")           // dependency parsing
        #expect(issue.url.absoluteString.hasSuffix("/issues/7"))
    }

    @Test("every page is followed via the Link header")
    func followsPagination() async throws {
        let transport = StubTransport { request, index in
            switch index {
            case 0:
                return .init(
                    body: "[\(self.issueJSON(number: 1))]",
                    headers: healthyRateLimitHeaders().merging([
                        "link": #"<https://api.github.com/repositories/1/issues?page=2>; rel="next", <https://api.github.com/repositories/1/issues?page=2>; rel="last""#,
                        "etag": "\"page-one\"",
                    ]) { _, new in new }
                )
            default:
                #expect(request.queryItems["page"] == "2")
                return .init(body: "[\(self.issueJSON(number: 2))]", headers: healthyRateLimitHeaders())
            }
        }
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.issues(owner: "me", name: "product-a")
        guard case .fetched(let issues, let etag) = response.value else {
            Issue.record("expected .fetched")
            return
        }
        #expect(issues.map(\.number) == [1, 2])
        #expect(transport.requests.count == 2)
        // The ETag is page one's — see the sort=updated rationale in the client.
        #expect(etag == "\"page-one\"")
    }

    @Test("a cached ETag is sent and a 304 short-circuits the fetch")
    func conditionalRequest() async throws {
        let transport = StubTransport(replies: [
            .init(status: 304, body: "", headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.issues(
            owner: "me", name: "product-a", ifNoneMatch: "\"abc\""
        )
        guard case .notModified = response.value else {
            Issue.record("expected .notModified")
            return
        }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(transport.requests.count == 1)
    }

    @Test("collections are sorted by recent activity, which is what makes one ETag enough")
    func sortsByUpdated() async throws {
        let transport = StubTransport(replies: [.init(headers: healthyRateLimitHeaders())])
        let client = GitHubClient(token: "t", transport: transport)

        _ = try await client.issues(owner: "me", name: "product-a")

        let query = try #require(transport.requests.first?.queryItems)
        #expect(query["sort"] == "updated")
        #expect(query["direction"] == "desc")
        #expect(query["state"] == "open")
        #expect(query["per_page"] == "100")
    }

    @Test("standard headers and bearer auth are set on every request")
    func standardHeaders() async throws {
        let transport = StubTransport(replies: [
            .init(body: #"{"default_branch": "trunk"}"#, headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "secret-token", transport: transport)

        _ = try await client.repository(owner: "me", name: "product-a")

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("the default branch is not assumed to be main")
    func readsDefaultBranch() async throws {
        let transport = StubTransport(replies: [
            .init(body: #"{"default_branch": "trunk"}"#, headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.repository(owner: "me", name: "product-a")
        #expect(response.value.defaultBranch == "trunk")
        #expect(response.rateLimit?.remaining == 4_000)
    }

    @Test("pull requests decode their head and base refs")
    func decodesPullRequests() async throws {
        let transport = StubTransport(replies: [
            .init(body: """
                [{ "number": 12, "title": "Add API", "state": "open", "draft": true,
                   "html_url": "https://github.com/me/product-a/pull/12",
                   "updated_at": "2026-07-30T12:00:00Z",
                   "head": { "ref": "issue-7" }, "base": { "ref": "main" } }]
                """, headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let response = try await client.pullRequests(owner: "me", name: "product-a")
        guard case .fetched(let pulls, _) = response.value, let pull = pulls.first else {
            Issue.record("expected one PR")
            return
        }
        #expect(pull.headRef == "issue-7")   // how a run's branch finds its PR
        #expect(pull.baseRef == "main")
        #expect(pull.isDraft)
    }
}

@Suite("GitHubClient / errors and rate limits")
struct GitHubClientErrorTests {
    @Test("an exhausted budget becomes a typed rateLimited error carrying the reset")
    func exhaustedBudget() async throws {
        let reset = Date().addingTimeInterval(900)
        let transport = StubTransport(replies: [
            .init(status: 403, body: #"{"message": "API rate limit exceeded"}"#, headers: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ])
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.issues(owner: "me", name: "product-a")
        }
        guard case .rateLimited(let resetAt) = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(abs(resetAt.timeIntervalSince(reset)) < 1)
    }

    @Test("Retry-After is honoured on a secondary rate limit")
    func retryAfter() async throws {
        let transport = StubTransport(replies: [
            .init(status: 429, body: "{}", headers: ["retry-after": "60"])
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.issues(owner: "me", name: "product-a")
        }
        guard case .rateLimited(let resetAt) = error else {
            Issue.record("expected .rateLimited")
            return
        }
        #expect(resetAt.timeIntervalSinceNow > 50 && resetAt.timeIntervalSinceNow <= 61)
    }

    @Test("a 403 with budget left is a permission problem, not a rate limit")
    func forbiddenIsNotRateLimited() async throws {
        let transport = StubTransport(replies: [
            .init(status: 403, body: #"{"message": "Resource not accessible"}"#,
                  headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.issues(owner: "me", name: "product-a")
        }
        guard case .httpFailure(let status, _, let message) = error else {
            Issue.record("expected .httpFailure, got \(String(describing: error))")
            return
        }
        #expect(status == 403)
        #expect(message == "Resource not accessible")
    }

    @Test("a bad token is not retryable, so the loop can stop shouting about it")
    func unauthorizedIsTerminal() async throws {
        let transport = StubTransport(replies: [.init(status: 401, body: "{}")])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.issues(owner: "me", name: "product-a")
        }
        #expect(error == .unauthorized)
        #expect(error?.isRetryable == false)
    }

    @Test("Link headers without a next relation end pagination")
    func linkHeaderParsing() {
        let client = GitHubClient(token: "t", transport: StubTransport(replies: []))

        #expect(client.nextPage(from: nil) == nil)
        #expect(client.nextPage(from: #"<https://api.github.com/x?page=9>; rel="last""#) == nil)
        #expect(client.nextPage(from: #"<https://api.github.com/x?page=3>; rel="next""#) == 3)
        #expect(client.nextPage(
            from: #"<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="next""#
        ) == 3)
    }
}
