import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

/// A two-column board with one issue in Ready and one PR in Review.
let boardJSON = """
    { "data": { "repository": { "projectV2": {
      "id": "PVT_1", "number": 3, "title": "Product A",
      "field": { "id": "PVTSSF_1", "name": "Status", "options": [
        { "id": "opt_ready", "name": "Ready" },
        { "id": "opt_active", "name": "In progress" },
        { "id": "opt_review", "name": "Review" }
      ] },
      "items": {
        "pageInfo": { "hasNextPage": false, "endCursor": null },
        "nodes": [
          { "id": "PVTI_1", "fieldValueByName": { "name": "Ready" },
            "content": { "__typename": "Issue", "number": 7, "title": "Add API",
              "url": "https://github.com/me/product-a/issues/7", "state": "OPEN",
              "assignees": { "nodes": [] } } },
          { "id": "PVTI_2", "fieldValueByName": { "name": "Review" },
            "content": { "__typename": "PullRequest", "number": 12, "title": "Add API",
              "url": "https://github.com/me/product-a/pull/12", "state": "OPEN",
              "assignees": { "nodes": [{ "login": "kmrifat" }] } } },
          { "id": "PVTI_3", "fieldValueByName": null, "content": null }
        ]
      }
    } } } }
    """

@Suite("Projects v2")
struct ProjectBoardTests {
    @Test("the board decodes into columns, cards and assignees")
    func decodesBoard() async throws {
        let transport = StubTransport(replies: [
            .init(body: boardJSON, headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let board = try await client.projectSnapshot(owner: "me", name: "product-a", number: 3).value

        #expect(board.projectId == "PVT_1")
        #expect(board.title == "Product A")
        #expect(board.statusField?.options.map(\.name) == ["Ready", "In progress", "Review"])
        #expect(board.items.count == 3)

        let ready = board.items(inColumn: "Ready")
        #expect(ready.map { $0.content?.number } == [7])
        #expect(ready.first?.content?.kind == .issue)

        let review = board.items(inColumn: "Review")
        #expect(review.first?.content?.kind == .pullRequest)
        #expect(review.first?.content?.assignees == ["kmrifat"])

        // A draft card with no status belongs to no column and must not appear
        // in Ready, or the dispatcher would try to work on nothing.
        #expect(board.items.last?.status == nil)
        #expect(board.items.last?.content == nil)
    }

    @Test("project item pagination follows the cursor")
    func paginatesItems() async throws {
        let firstPage = boardJSON.replacingOccurrences(
            of: #""pageInfo": { "hasNextPage": false, "endCursor": null }"#,
            with: #""pageInfo": { "hasNextPage": true, "endCursor": "CUR1" }"#
        )
        let transport = StubTransport { _, index in
            .init(body: index == 0 ? firstPage : boardJSON, headers: healthyRateLimitHeaders())
        }
        let client = GitHubClient(token: "t", transport: transport)

        let board = try await client.projectSnapshot(owner: "me", name: "product-a", number: 3).value

        #expect(transport.requests.count == 2)
        #expect(board.items.count == 6)

        let secondBody = try #require(transport.requests.last?.httpBody)
        #expect(String(decoding: secondBody, as: UTF8.self).contains("CUR1"))
    }

    @Test("GraphQL errors are failures even though the status is 200")
    func graphQLErrorsAreFailures() async throws {
        let transport = StubTransport(replies: [
            .init(body: #"{"data": null, "errors": [{"message": "Could not resolve to a ProjectV2"}]}"#,
                  headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.projectSnapshot(owner: "me", name: "product-a", number: 99)
        }
        guard case .graphQLErrors(let messages) = error else {
            Issue.record("expected .graphQLErrors, got \(String(describing: error))")
            return
        }
        #expect(messages == ["Could not resolve to a ProjectV2"])
    }

    @Test("a missing project is a 404, not an empty board")
    func missingProject() async throws {
        let transport = StubTransport(replies: [
            .init(body: #"{"data": {"repository": {"projectV2": null}}}"#,
                  headers: healthyRateLimitHeaders())
        ])
        let client = GitHubClient(token: "t", transport: transport)

        let error = await #expect(throws: GitHubError.self) {
            try await client.projectSnapshot(owner: "me", name: "product-a", number: 99)
        }
        guard case .notFound = error else {
            Issue.record("expected .notFound, got \(String(describing: error))")
            return
        }
    }
}

@Suite("Column-move mutation")
struct ProjectBoardMutationTests {
    private func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            projectId: "PVT_1", number: 3, title: "Product A",
            statusField: ProjectStatusField(id: "PVTSSF_1", name: "Status", options: [
                ProjectStatusOption(id: "opt_ready", name: "Ready"),
                ProjectStatusOption(id: "opt_active", name: "In progress"),
            ]),
            items: [ProjectItem(id: "PVTI_1", status: "Ready", content: nil)]
        )
    }

    @Test("resolves the column name to its option id")
    func buildsMutation() throws {
        let board = snapshot()
        let request = try ProjectBoardMutation.moveCard(
            board.items[0], to: "In progress", in: board
        )

        #expect(request.query.contains("updateProjectV2ItemFieldValue"))
        #expect(request.variables["projectId"] == .string("PVT_1"))
        #expect(request.variables["itemId"] == .string("PVTI_1"))
        #expect(request.variables["fieldId"] == .string("PVTSSF_1"))
        #expect(request.variables["optionId"] == .string("opt_active"))
    }

    @Test("a column name that is not on the board fails loudly")
    func unknownColumn() throws {
        let board = snapshot()
        let error = #expect(throws: ProjectBoardMutation.BuildError.self) {
            try ProjectBoardMutation.moveCard(board.items[0], to: "Done", in: board)
        }
        // A config typo must not become a silent no-op at GitHub.
        #expect(error?.description.contains("no column named \"Done\"") == true)
        #expect(error?.description.contains("Ready, In progress") == true)
    }

    /// The mutation was written in phase 1 and left uncalled; the dispatcher in
    /// phase 6 is the *only* thing allowed to reach it. Keeping the guard — with
    /// an explicit allow-list — means board writes can still never appear
    /// somewhere by accident.
    @Test("only the dispatcher and the write client reference the board mutation")
    func mutationIsWiredUpOnlyWhereIntended() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources", directoryHint: .isDirectory)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "source enumeration found nothing — the path above is wrong")

        let allowed: Set<String> = [
            "ProjectBoardMutation.swift",   // where it is defined
            "GitHubClient+Write.swift",     // the one call site
        ]
        let offenders = try files
            .filter { !allowed.contains($0.lastPathComponent) }
            .filter {
                let text = try String(contentsOf: $0, encoding: .utf8)
                return text.contains("updateProjectV2ItemFieldValue")
                    || text.contains("ProjectBoardMutation")
            }
        #expect(offenders.map(\.lastPathComponent) == [])
    }
}
