//
//  GitHubIssue.swift
//  workflow-manager
//
//  Read-only mirrors of what `gh` returns. Deliberately *not* SwiftData models:
//  GitHub owns issues, and nothing here is ever written back to GitHub.
//
//  `GitHubIssue` is `Encodable` as well as `Decodable` only so `IssueCache` can
//  keep the last fetch as an opaque blob. The conformance is synthesized both
//  ways, so the encoder emits exactly the keys the decoder reads and the round
//  trip is stable. That blob is a cache, not a source of truth: a fetch replaces
//  it wholesale, and deleting it loses nothing.
//

import Foundation

struct GitHubRepository: Decodable, Sendable, Equatable {
    let owner: String
    let name: String
    let defaultBranch: String

    var slug: String { "\(owner)/\(name)" }

    // `gh repo view --json nameWithOwner,defaultBranchRef`
    private enum CodingKeys: String, CodingKey {
        case nameWithOwner
        case defaultBranchRef
    }

    private struct BranchRef: Decodable { let name: String }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nameWithOwner = try container.decode(String.self, forKey: .nameWithOwner)
        let parts = nameWithOwner.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .nameWithOwner, in: container,
                debugDescription: "expected owner/name, got \"\(nameWithOwner)\""
            )
        }
        owner = String(parts[0])
        name = String(parts[1])
        defaultBranch = try container
            .decodeIfPresent(BranchRef.self, forKey: .defaultBranchRef)?.name ?? "main"
    }

    init(owner: String, name: String, defaultBranch: String) {
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
    }
}

struct GitHubIssue: Codable, Sendable, Identifiable, Equatable {
    struct Label: Codable, Sendable, Equatable, Identifiable {
        let name: String
        /// Six hex digits, no leading `#`.
        let color: String

        var id: String { name }
    }

    struct User: Codable, Sendable, Equatable, Identifiable {
        let login: String
        /// Absent for some accounts, and null for bots.
        let name: String?

        var id: String { login }

        /// Real name when GitHub has one, otherwise the handle.
        var displayName: String {
            guard let name, !name.isEmpty else { return login }
            return name
        }
    }

    struct Milestone: Codable, Sendable, Equatable {
        let title: String
    }

    let number: Int
    let title: String
    let state: String
    let url: URL
    let body: String
    let labels: [Label]
    let assignees: [User]
    let author: User?
    let milestone: Milestone?
    let createdAt: Date
    let updatedAt: Date

    var id: Int { number }

    var isOpen: Bool { state.uppercased() == "OPEN" }

    /// Assignment is how a run claims an issue, so it is the one piece of issue
    /// state the board leans on.
    var isClaimed: Bool { !assignees.isEmpty }

    /// Free-text match for the search field. `query` must already be lowercased.
    ///
    /// Matches the number both bare and as `#42`, so either way of typing it
    /// finds the issue.
    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        if "#\(number)".hasPrefix(query) || "\(number)" == query { return true }
        if title.lowercased().contains(query) { return true }
        if body.lowercased().contains(query) { return true }
        if labels.contains(where: { $0.name.lowercased().contains(query) }) { return true }
        if assignees.contains(where: { $0.login.lowercased().contains(query) }) { return true }
        if let author, author.login.lowercased().contains(query) { return true }
        return false
    }

    /// The `area` label the dispatcher will eventually key off.
    var areaLabel: String? {
        let areas: Set<String> = ["api", "ui", "db", "infra"]
        return labels.first { areas.contains($0.name.lowercased()) }?.name
    }
}
