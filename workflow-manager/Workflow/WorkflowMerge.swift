//
//  WorkflowMerge.swift
//  workflow-manager
//
//  Decides what an incoming `.taskboard/tasks.json` should change on the board,
//  and what the app should write back.
//
//  Pure and `nonisolated`: it takes value types and returns a plan. Nothing here
//  touches SwiftData, which is what lets the rule below be reasoned about — and
//  tested — on its own.
//
//  ## Conflict resolution: field ownership
//
//  Each field is owned by whichever side can actually observe it.
//
//  * **Claude owns** `status`, `branch`, `prUrl`. It is the only party that
//    knows it has begun work or opened a pull request — that is the entire
//    point of the integration.
//  * **The app owns** `title`, `details`, `githubIssue`, `requested`, and
//    column membership beyond what `status` implies. The person is the only
//    party who knows what a card *means*.
//
//  Plain per-field last-writer-wins was rejected: the agent rewrites the whole
//  array in one atomic write, so every row carries the same timestamp, and a
//  title the user typed a second earlier would be clobbered by a rewrite that
//  never intended to touch it. `updatedAt` still breaks ties *within* a side and
//  gates tombstones.
//

import Foundation

nonisolated enum WorkflowMerge {

    /// A card, reduced to what merging needs.
    struct LocalTask: Sendable, Equatable {
        var id: String
        var title: String
        var details: String
        var status: WorkflowTasksFile.Status
        var githubIssue: Int?
        var branch: String?
        var prUrl: String?
        var requested: Bool
        var column: String?
        var updatedAt: Date
    }

    /// What the app last wrote for a row, per Claude-owned field.
    ///
    /// This is the evidence that a row changed. `TaskRow.source` is the agent's
    /// own claim about itself, and agents do not make it reliably: observed
    /// behaviour is to edit `status` in place and leave the `"source": "app"`
    /// the app stamped on the row in its last write-back. Believing `source`
    /// therefore *discarded* every `in_progress` and `review` write and then
    /// reverted the file to the board's older value — cards appeared to jump
    /// from `todo` straight to `done`, because `done` was the one write the
    /// agent decorated correctly.
    ///
    /// Comparing against what we last wrote needs no cooperation from the
    /// writer, and answers the question `source` was standing in for exactly:
    /// is this value ours, or somebody's news?
    struct Baseline: Sendable, Equatable {
        var status: WorkflowTasksFile.Status
        var branch: String?
        var prUrl: String?
    }

    /// What to change on a card the board already has.
    struct Change: Sendable, Equatable {
        var id: String
        var status: WorkflowTasksFile.Status?
        var branch: String?
        var prUrl: String?

        var isEmpty: Bool { status == nil && branch == nil && prUrl == nil }
    }

    struct Plan: Sendable {
        /// Cards to update, Claude-owned fields only.
        var changes: [Change] = []
        /// Rows the agent filed that the board has never seen.
        var creations: [WorkflowTasksFile.TaskRow] = []
        /// What the app should write back, reconciling both sides.
        var nextEnvelope: WorkflowTasksFile.Envelope?
        /// Whether that write is actually needed.
        var fileNeedsRewrite = false
        /// Set when the file came from a newer version of the format. Nothing
        /// is applied and nothing is written.
        var rejectedAsNewer = false
    }

    /// Merges an incoming file against the board.
    ///
    /// - Parameters:
    ///   - allowCreations: whether rows the agent invented become cards.
    ///   - baseline: the Claude-owned fields as the app last wrote them, keyed
    ///     by row id. Empty for the first read of a file the app did not write,
    ///     where `TaskRow.source` is the only signal there is.
    static func merge(
        local: [LocalTask],
        incoming: WorkflowTasksFile.Envelope,
        project: WorkflowTasksFile.ProjectRef,
        allowCreations: Bool,
        baseline: [String: Baseline] = [:],
        now: Date
    ) -> Plan {
        var plan = Plan()

        // A file written by a newer app knows things this one does not.
        // Applying it would guess; overwriting it would destroy. Do neither.
        guard !incoming.isFromNewerVersion else {
            plan.rejectedAsNewer = true
            return plan
        }

        let tombstones = WorkflowTasksFile.pruningTombstones(incoming.tombstones, now: now)
        let deleted = Dictionary(
            tombstones.map { ($0.id, $0.deletedAt) },
            uniquingKeysWith: { first, second in max(first, second) }
        )
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var seen: Set<String> = []

        for row in incoming.tasks {
            guard !seen.contains(row.id) else { continue }
            seen.insert(row.id)

            if let existing = localByID[row.id] {
                // Only the fields Claude owns, and only where the file says
                // something we did not put there ourselves.
                //
                // Each field is tested against its own baseline rather than the
                // row being accepted or rejected whole. A value equal to our
                // last write is not news even if the board has since moved on —
                // that is the case the old `source` check protected: the user
                // drags a card, and a re-read of the not-yet-rewritten file
                // must not drag it back. With no baseline, `source` stands in.
                var change = Change(id: row.id)
                if let base = baseline[row.id] {
                    if row.status != existing.status, row.status != base.status {
                        change.status = row.status
                    }
                    if let branch = row.branch, branch != existing.branch, branch != base.branch {
                        change.branch = branch
                    }
                    if let prUrl = row.prUrl, prUrl != existing.prUrl, prUrl != base.prUrl {
                        change.prUrl = prUrl
                    }
                } else if row.source == .claude {
                    if row.status != existing.status { change.status = row.status }
                    if let branch = row.branch, branch != existing.branch { change.branch = branch }
                    if let prUrl = row.prUrl, prUrl != existing.prUrl { change.prUrl = prUrl }
                }
                if !change.isEmpty { plan.changes.append(change) }
                continue
            }

            // Unknown locally. Either the user deleted it, or the agent filed
            // new work.
            if let deletedAt = deleted[row.id] {
                // Deleted after the agent last touched it — stay deleted.
                if deletedAt >= row.updatedAt { continue }
            }
            if allowCreations, row.source == .claude {
                plan.creations.append(row)
            }
        }

        // What the app writes back: every card it has, plus surviving
        // tombstones. A card missing from the incoming file is simply re-added —
        // deletion only ever flows app to file.
        let merged = local.map { task in
            WorkflowTasksFile.TaskRow(
                id: task.id,
                title: task.title,
                status: appliedStatus(for: task, in: plan),
                details: task.details.isEmpty ? nil : task.details,
                githubIssue: task.githubIssue,
                branch: appliedBranch(for: task, in: plan),
                prUrl: appliedPRURL(for: task, in: plan),
                requested: task.requested,
                column: task.column,
                updatedAt: task.updatedAt,
                source: .app
            )
        }

        let creationRows = plan.creations
        let next = WorkflowTasksFile.Envelope(
            project: project,
            updatedAt: now,
            writer: .app,
            tasks: merged + creationRows,
            tombstones: tombstones
        )
        plan.nextEnvelope = next
        // Only rewrite when the file does not already say what we would say.
        plan.fileNeedsRewrite = !equivalent(incoming, next)
        return plan
    }

    /// The envelope the app writes when nothing came in — the initial write, and
    /// every write driven by a board edit.
    static func envelope(
        local: [LocalTask],
        project: WorkflowTasksFile.ProjectRef,
        tombstones: [WorkflowTasksFile.Tombstone],
        now: Date
    ) -> WorkflowTasksFile.Envelope {
        WorkflowTasksFile.Envelope(
            project: project,
            updatedAt: now,
            writer: .app,
            tasks: local.map { task in
                WorkflowTasksFile.TaskRow(
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    details: task.details.isEmpty ? nil : task.details,
                    githubIssue: task.githubIssue,
                    branch: task.branch,
                    prUrl: task.prUrl,
                    requested: task.requested,
                    column: task.column,
                    updatedAt: task.updatedAt,
                    source: .app
                )
            },
            tombstones: WorkflowTasksFile.pruningTombstones(tombstones, now: now)
        )
    }

    // MARK: - Plumbing

    private static func appliedStatus(
        for task: LocalTask,
        in plan: Plan
    ) -> WorkflowTasksFile.Status {
        plan.changes.first { $0.id == task.id }?.status ?? task.status
    }

    private static func appliedBranch(for task: LocalTask, in plan: Plan) -> String? {
        plan.changes.first { $0.id == task.id }?.branch ?? task.branch
    }

    private static func appliedPRURL(for task: LocalTask, in plan: Plan) -> String? {
        plan.changes.first { $0.id == task.id }?.prUrl ?? task.prUrl
    }

    /// Compares everything except the envelope timestamp and writer.
    ///
    /// Without this the app would rewrite the file on every read purely because
    /// `updatedAt` moved, and each rewrite would wake the watcher again.
    private static func equivalent(
        _ lhs: WorkflowTasksFile.Envelope,
        _ rhs: WorkflowTasksFile.Envelope
    ) -> Bool {
        lhs.version == rhs.version
            && lhs.project == rhs.project
            && lhs.statuses == rhs.statuses
            && lhs.tombstones == rhs.tombstones
            && lhs.tasks == rhs.tasks
    }
}
