//
//  IssueCacheEntry.swift
//  workflow-manager
//
//  One row per project holding the last issue list we fetched, so opening the
//  Issues board shows something immediately instead of a spinner.
//
//  This is a *cache*, not a store: GitHub still owns issues. Deleting every row
//  loses nothing — the next fetch rebuilds it. Nothing that cannot be re-fetched
//  may be kept here.
//
//  The payload is an opaque JSON blob rather than one row per issue. Issues nest
//  labels, assignees, an author and a milestone; flattening those would mean
//  either four more models with four more cascade rules or JSON columns anyway.
//  Nothing queries issues through `#Predicate` — `GitHubIssuesView` filters ≤100
//  of them in memory through `GitHubIssue.matches` — so the blob costs nothing
//  and makes "GitHub wins, overwrite local" a single assignment.
//

import Foundation
import SwiftData

@Model
final class IssueCacheEntry {
    /// Deliberately *not* a `@Relationship` to `Project`. A relationship would
    /// pull the cache into the board's delete graph, and `WorkItem` already
    /// documents why extra cascade paths are avoided. A plain id plus an
    /// explicit prune keeps this genuinely disposable.
    var projectUUID: UUID = UUID()

    /// The repository the payload belongs to. A mismatch is a cache miss, so
    /// relinking a project never briefly shows another repository's issues.
    var repoPath: String = ""
    var repoSlug: String = ""

    /// A JSON array of `GitHubIssue`, ISO-8601 dates.
    var payload: Data = Data()
    var fetchedAt: Date = Date.now

    /// Shown in the UI without paying to decode the payload.
    var issueCount: Int = 0

    /// Bumped when `GitHubIssue`'s shape changes. A mismatch is a cache miss,
    /// which is cheaper and safer than a migration for data we can refetch.
    var payloadVersion: Int = 1

    init(
        projectUUID: UUID = UUID(),
        repoPath: String = "",
        repoSlug: String = "",
        payload: Data = Data(),
        fetchedAt: Date = .now,
        issueCount: Int = 0,
        payloadVersion: Int = 1
    ) {
        self.projectUUID = projectUUID
        self.repoPath = repoPath
        self.repoSlug = repoSlug
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.issueCount = issueCount
        self.payloadVersion = payloadVersion
    }
}
