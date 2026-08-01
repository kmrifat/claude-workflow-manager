//
//  BoardSnapshotBuilder.swift
//  workflow-manager
//
//  SwiftData in, plain values out. The one place the board's models are turned
//  into something that can leave this process.
//
//  ## `isDeleted`, four times
//
//  SwiftData leaves a deleted object in its relationship arrays until the
//  context saves. `WorkflowSyncModel.snapshot(of:)` already filters cards for
//  this reason — an unfiltered one gets written to `tasks.json` and the agent
//  recreates it from our own row. The phone has the same trap in three more
//  places, and each fails differently:
//
//  * a deleted **card** appears on the phone and can be tapped;
//  * a deleted **subtask** inflates a card's "2 of 5" counter;
//  * a deleted **blocker** keeps a card greyed out and un-sendable, with no
//    visible reason why — the blocking card is not on the board any more;
//  * a deleted **column** shows up empty and accepts drops into nothing.
//
//  None of them throw. They just look like bugs elsewhere.
//

import Foundation
import SwiftData
import ClaudeWMWire

@MainActor
enum BoardSnapshotBuilder {

    // MARK: - Snapshot

    static func snapshot(of project: Project, now: Date = .now) -> BoardSnapshot {
        BoardSnapshot(
            project: reference(to: project),
            columns: project.orderedColumns.map(column(from:)),
            revision: revision(of: project),
            capturedAt: wireDate(now)
        )
    }

    /// Truncated to the second, because that is all the wire carries — the
    /// `.iso8601` strategy emits no fractional part.
    ///
    /// Doing it here rather than leaving it to the encoder makes the boundary
    /// lossless: a snapshot equals its own round trip, so a client may compare
    /// two snapshots directly. Left alone, every snapshot built from real model
    /// objects differs from its decoded self on sub-second noise, and the
    /// resulting "the board keeps changing" bug is a genuinely nasty one to
    /// chase.
    private static func wireDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func wireDate(_ date: Date?) -> Date? {
        date.map(wireDate)
    }

    static func reference(to project: Project) -> WireProjectRef {
        WireProjectRef(
            id: project.uuid.uuidString,
            name: project.name.isEmpty ? "Untitled Project" : project.name,
            repoSlug: project.repoSlug
        )
    }

    /// For the phone's project picker. Deleted projects are filtered for the
    /// same reason everything else is.
    static func references(to projects: [Project]) -> [WireProjectRef] {
        projects.filter { !$0.isDeleted }.map(reference(to:))
    }

    private static func column(from column: BoardColumn) -> WireColumn {
        WireColumn(
            id: column.uuid.uuidString,
            name: column.name,
            role: column.role.map(wireRole(for:)),
            wipLimit: column.wipLimit,
            isCompletionColumn: column.isCompletionColumn,
            cards: column.orderedItems.map(card(from:))
        )
    }

    private static func card(from item: WorkItem) -> WireCard {
        let subtasks = item.orderedSubtasks
        return WireCard(
            id: item.uuid.uuidString,
            title: item.title,
            details: item.details,
            priority: wirePriority(for: item.priority),
            owner: item.owner.isEmpty ? nil : item.owner,
            startDate: wireDate(item.startDate),
            dueDate: wireDate(item.dueDate),
            tags: item.tags,
            isDone: item.isDone,
            githubIssue: item.githubIssueNumber,
            githubRepoSlug: item.githubRepoSlug,
            branch: item.workflowBranch,
            prURL: item.workflowPRURL,
            requested: item.workflowRequested,
            // `blockedBy` is the raw relationship, so this one still filters:
            // the accessor that does it for you is `openBlockers`, and the phone
            // needs every blocker, done or not.
            blockedBy: item.blockedBy
                .filter { !$0.isDeleted }
                .map { $0.uuid.uuidString },
            subtaskCount: subtasks.count,
            subtasksDone: subtasks.count(where: \.isDone),
            // `WorkItem` has no `updatedAt`; this is the same stand-in
            // `WorkflowSyncModel.snapshot(of:)` uses, so a card's timestamp
            // means one thing whether it reaches a phone or `tasks.json`.
            updatedAt: wireDate(item.completedAt ?? item.createdAt)
        )
    }

    // MARK: - Revision

    /// A hash of everything a phone can see, so `event` can carry a number
    /// instead of a board and a client can tell whether its copy is current.
    ///
    /// Two properties worth being explicit about:
    ///
    /// * **Column identity and order are in it.** Renaming a column or dragging
    ///   one changes what the phone should draw, even though no card moved.
    /// * **It is only meaningful within one run of the app.** `Hasher` is seeded
    ///   per process, so relaunching the Mac changes every revision and every
    ///   phone refetches once. That is the correct trade: a stable hash would
    ///   have to be hand-rolled, and being wrong about *unchanged* is far worse
    ///   than one redundant fetch after a launch.
    ///
    /// Distinct from `WorkflowSyncModel.boardRevision(of:)`, which returns 0
    /// unless the project is syncing to `tasks.json` — phone access and file
    /// sync are separately switchable, so they cannot share that gate.
    static func revision(of project: Project) -> Int {
        var hasher = Hasher()
        for column in project.orderedColumns {
            hasher.combine(column.uuid)
            hasher.combine(column.name)
            hasher.combine(column.roleRaw)
            hasher.combine(column.wipLimit)
            hasher.combine(column.isCompletionColumn)
            for item in column.orderedItems {
                hasher.combine(item.uuid)
                hasher.combine(item.title)
                hasher.combine(item.details)
                hasher.combine(item.priorityRaw)
                hasher.combine(item.owner)
                hasher.combine(item.startDate)
                hasher.combine(item.dueDate)
                hasher.combine(item.tags)
                hasher.combine(item.completedAt)
                hasher.combine(item.githubIssueNumber)
                hasher.combine(item.workflowRequested)
                hasher.combine(item.workflowBranch)
                hasher.combine(item.workflowPRURL)
                // Subtask *counts* are on the card, so their state is visible
                // to the phone and belongs in the revision.
                for subtask in item.orderedSubtasks {
                    hasher.combine(subtask.uuid)
                    hasher.combine(subtask.isDone)
                }
                for blocker in item.blockedBy where !blocker.isDeleted {
                    hasher.combine(blocker.uuid)
                }
            }
        }
        return hasher.finalize()
    }

    // MARK: - Enum bridging
    //
    // Written out rather than bridged through raw values. The wire spellings are
    // a contract with a shipped phone; the model's are ours to change. A switch
    // means adding a case to either one fails to compile here, which is exactly
    // where that decision should be made.

    private static func wireRole(for role: ColumnRole) -> WireColumnRole {
        switch role {
        case .todo:       .todo
        case .inProgress: .inProgress
        case .review:     .review
        case .done:       .done
        }
    }

    private static func wirePriority(for priority: Priority) -> WirePriority {
        switch priority {
        case .low:    .low
        case .normal: .normal
        case .high:   .high
        case .urgent: .urgent
        }
    }
}
