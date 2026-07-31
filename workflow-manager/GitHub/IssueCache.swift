//
//  IssueCache.swift
//  workflow-manager
//
//  Reads and writes the one `IssueCacheEntry` row a project owns.
//
//  Two rules the rest of the app depends on:
//
//  * **A fetch replaces the row wholesale.** No diff, no per-issue eviction.
//    Closed, deleted and transferred issues disappear because
//    `gh issue list --state open` stops returning them and the whole array is
//    replaced. That is what "GitHub wins: overwrite local" means here.
//  * **A failed fetch never touches the row.** Stale issues on screen beat an
//    empty board, so long as the staleness is visible.
//

import Foundation
import SwiftData

/// The codec, split out so encoding and decoding can run off the main actor —
/// this target isolates every type to `@MainActor` unless told otherwise.
nonisolated enum IssueCodec {
    static func encode(_ issues: [GitHubIssue]) throws -> Data {
        try encoder.encode(issues)
    }

    static func decode(_ data: Data) throws -> [GitHubIssue] {
        try decoder.decode([GitHubIssue].self, from: data)
    }

    /// Matches `GitHubCLI.decoder`, so a payload we wrote reads back the same
    /// way one straight from `gh` does.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

@MainActor
enum IssueCache {
    /// How long a cached list is worth showing before the view refetches.
    ///
    /// One number for two behaviours: entering the Issues board refetches only
    /// past this age, and the board's periodic refresh runs at the same cadence.
    /// `RepositoryStatusModel.cacheLifetime` is the same idea for git summaries.
    static let ttl: TimeInterval = {
        let override = UserDefaults.standard.double(forKey: "IssueCacheTTLSeconds")
        return override > 0 ? override : 120
    }()

    /// Bumped when `GitHubIssue`'s shape changes; an older payload is a miss.
    static let payloadVersion = 1

    struct Hit: Sendable {
        let issues: [GitHubIssue]
        let fetchedAt: Date

        var isStale: Bool {
            Date.now.timeIntervalSince(fetchedAt) > IssueCache.ttl
        }
    }

    /// The cached issues for `project`, or `nil` on a miss.
    ///
    /// A miss is any of: no row, a different repository, an older payload
    /// version, or a payload that no longer decodes. All four are cheap to
    /// recover from — we just fetch.
    static func load(for project: Project, in context: ModelContext) async -> Hit? {
        guard let repoPath = project.repoPath,
              let entry = fetchEntry(for: project.uuid, in: context),
              entry.repoPath == repoPath,
              entry.payloadVersion == payloadVersion
        else { return nil }

        let payload = entry.payload
        let issues = await Task.detached { try? IssueCodec.decode(payload) }.value
        guard let issues else { return nil }
        return Hit(issues: issues, fetchedAt: entry.fetchedAt)
    }

    /// Replaces the project's cached list. Silently does nothing if the project
    /// has no repository or the payload cannot be encoded — a cache that fails
    /// to write is a slow board, not a broken one.
    static func store(
        _ issues: [GitHubIssue],
        for project: Project,
        in context: ModelContext
    ) async {
        guard let repoPath = project.repoPath else { return }

        let payload = await Task.detached { try? IssueCodec.encode(issues) }.value
        guard let payload else { return }

        withoutUndo(context) {
            let entry = fetchEntry(for: project.uuid, in: context)
                ?? insertEntry(for: project.uuid, in: context)
            entry.repoPath = repoPath
            entry.repoSlug = project.repoSlug ?? ""
            entry.payload = payload
            entry.fetchedAt = .now
            entry.issueCount = issues.count
            entry.payloadVersion = payloadVersion
        }
    }

    static func remove(for project: Project, in context: ModelContext) {
        withoutUndo(context) {
            if let entry = fetchEntry(for: project.uuid, in: context) {
                context.delete(entry)
            }
        }
    }

    /// Drops rows whose project is gone. Called once at launch — there is no
    /// relationship to cascade from, which is the point.
    static func prune(keeping live: Set<UUID>, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<IssueCacheEntry>())) ?? []
        let orphans = all.filter { !live.contains($0.projectUUID) }
        guard !orphans.isEmpty else { return }
        withoutUndo(context) {
            for entry in orphans { context.delete(entry) }
        }
    }

    // MARK: - Plumbing

    private static func fetchEntry(
        for projectUUID: UUID,
        in context: ModelContext
    ) -> IssueCacheEntry? {
        var descriptor = FetchDescriptor<IssueCacheEntry>(
            predicate: #Predicate { $0.projectUUID == projectUUID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func insertEntry(
        for projectUUID: UUID,
        in context: ModelContext
    ) -> IssueCacheEntry {
        let entry = IssueCacheEntry(projectUUID: projectUUID)
        context.insert(entry)
        return entry
    }

    /// The main context carries an `UndoManager` so ⌘Z undoes one drag. Cache
    /// writes are not user edits: without this, ⌘Z after a background refresh
    /// undoes something the user never did and cannot see.
    ///
    /// The `save` is the load-bearing part, not a flush. SwiftData registers its
    /// undo action when the context *saves*, not when the object is mutated, so
    /// disabling registration around the mutation alone achieves nothing — the
    /// next autosave would register it after the window had closed. Saving here
    /// makes the change land while registration is still off.
    private static func withoutUndo(_ context: ModelContext, _ body: () -> Void) {
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        body()
        try? context.save()
        undoManager?.enableUndoRegistration()
    }
}
