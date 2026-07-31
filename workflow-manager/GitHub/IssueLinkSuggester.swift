//
//  IssueLinkSuggester.swift
//  workflow-manager
//
//  Proposes links between existing cards and issues by comparing titles.
//
//  This is a *bootstrap*, not a sync. It runs when the user asks, it returns
//  suggestions, and it never writes anything — title matching is too fragile to
//  maintain a link with. A rename on either side would silently repoint a card,
//  and two issues called "Fix login" would fight over the same one.
//
//  Pure Foundation and no SwiftData, like `MarkdownBlock`, so the matching can
//  be exercised on its own.
//

import Foundation

nonisolated enum IssueLinkSuggester {

    /// A card eligible for linking, reduced to what matching needs.
    struct Candidate: Sendable, Equatable {
        let uuid: UUID
        let title: String

        init(uuid: UUID, title: String) {
            self.uuid = uuid
            self.title = title
        }
    }

    struct Suggestion: Sendable, Identifiable, Equatable {
        let itemUUID: UUID
        let itemTitle: String
        let issueNumber: Int
        let issueTitle: String
        /// 1.0 for an exact match after normalisation, otherwise the token
        /// overlap between the two titles.
        let confidence: Double

        var id: UUID { itemUUID }
        var isExact: Bool { confidence >= 0.999 }
    }

    /// Strips the decoration that makes two titles for the same work look
    /// different: a leading issue reference, a bracketed area, a
    /// conventional-commit prefix, punctuation, and repeated whitespace.
    static func normalize(_ title: String) -> String {
        var text = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading `#123` / `123 -` issue references.
        if let match = text.range(of: "^#?\\d+\\s*[-–—:.)]\\s*", options: .regularExpression) {
            text.removeSubrange(match)
        }
        // Leading `[area]` tags.
        while let match = text.range(of: "^\\[[^\\]]*\\]\\s*", options: .regularExpression) {
            text.removeSubrange(match)
        }
        // Conventional-commit prefixes.
        if let match = text.range(
            of: "^(feat|fix|chore|docs|refactor|test|perf|build|ci|style)(\\([^)]*\\))?!?:\\s*",
            options: .regularExpression
        ) {
            text.removeSubrange(match)
        }

        let stripped = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// One suggestion per card, best issue first.
    ///
    /// Cards that already carry a number are skipped, and so are issues another
    /// card already claims — the point is to fill gaps, not to re-litigate
    /// links the user has already made.
    static func suggestions(
        for items: [Candidate],
        issues: [GitHubIssue],
        claimedIssueNumbers: Set<Int> = [],
        minimumConfidence: Double = 0.75
    ) -> [Suggestion] {
        let available = issues.filter { !claimedIssueNumbers.contains($0.number) }
        guard !available.isEmpty, !items.isEmpty else { return [] }

        let issueKeys = available.map { (issue: $0, tokens: tokens(of: $0.title)) }

        var used: Set<Int> = []
        var results: [Suggestion] = []

        // Exact matches first, so a perfect pair is never consumed by a fuzzy
        // one that happened to be considered earlier.
        for pass in 0..<2 {
            for item in items where !results.contains(where: { $0.itemUUID == item.uuid }) {
                let itemTokens = tokens(of: item.title)
                guard !itemTokens.isEmpty else { continue }

                var best: (issue: GitHubIssue, score: Double)?
                for entry in issueKeys where !used.contains(entry.issue.number) {
                    guard !entry.tokens.isEmpty else { continue }
                    let score = itemTokens == entry.tokens
                        ? 1.0
                        : jaccard(itemTokens, entry.tokens)
                    if score > (best?.score ?? 0) { best = (entry.issue, score) }
                }

                guard let best else { continue }
                let threshold = pass == 0 ? 1.0 : minimumConfidence
                guard best.score >= threshold else { continue }

                used.insert(best.issue.number)
                results.append(
                    Suggestion(
                        itemUUID: item.uuid,
                        itemTitle: item.title,
                        issueNumber: best.issue.number,
                        issueTitle: best.issue.title,
                        confidence: best.score
                    )
                )
            }
        }

        return results.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Plumbing

    private static func tokens(of title: String) -> Set<String> {
        Set(normalize(title).split(separator: " ").map(String.init))
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }
}
