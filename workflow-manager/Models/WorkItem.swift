//
//  WorkItem.swift
//  workflow-manager
//
//  A card on the board. Named `WorkItem` because `Task` belongs to Swift
//  concurrency.
//

import Foundation
import SwiftData

@Model
final class WorkItem {
    var uuid: UUID = UUID()
    var title: String = ""
    var details: String = ""
    var priorityRaw: Int = Priority.normal.rawValue
    var startDate: Date?
    var dueDate: Date?
    var owner: String = ""
    /// Persisted as an opaque blob — cannot be used inside a `#Predicate`,
    /// so all tag filtering happens in memory.
    var tags: [String] = []
    var createdAt: Date = Date.now
    var completedAt: Date?
    var sortOrder: Double = 0

    // MARK: - Linked GitHub issue
    //
    // GitHub is where the team collaborates; the board is where the work is
    // tracked locally. This is the join, and it is always explicit — set by
    // creating a card from an issue or by linking one by hand. Titles are
    // matched only to *suggest* links (`IssueLinkSuggester`), never to maintain
    // them: a rename on either side would silently repoint the card.
    //
    // Optional with no default, like `Project`'s repository fields, so this
    // stays a lightweight migration.

    var githubIssueNumber: Int?
    /// `owner/name` at the time of linking. Guards against a project being
    /// relinked to a different repository, which would otherwise repoint every
    /// number on the board at once.
    var githubRepoSlug: String?

    // MARK: - Claude sync
    //
    // Mirrored through `.taskboard/tasks.json`. Ownership is split by who can
    // actually observe the field: the user decides what is *requested*, and only
    // the agent knows which branch it made or which PR it opened.

    /// The user pressed "Send to Claude". App-owned; the agent reads it to find
    /// work and never writes it.
    var workflowRequested: Bool = false
    /// Reported by the agent. Claude-owned — nothing local can know these.
    var workflowBranch: String?
    var workflowPRURL: String?

    /// Inverse is declared on `BoardColumn.items`. There is deliberately no
    /// direct `project` relationship: two cascade paths to the same object
    /// confuse SwiftData's delete rules, and `column?.project` is free.
    var column: BoardColumn?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.item)
    var subtasks: [Subtask] = []

    // MARK: - Dependencies
    //
    // A card can depend on other cards ("blocked by"). Local only — deliberately
    // not mirrored into `.taskboard/tasks.json`, so dependencies gate what a
    // person does on the board, not what the agent picks up. Delete rule is the
    // default nullify: losing a blocker unblocks its dependents, never cascades.

    /// The cards that must be done before this one.
    @Relationship var blockedBy: [WorkItem] = []
    /// Inverse of `blockedBy`: the cards this one is holding up.
    @Relationship(inverse: \WorkItem.blockedBy) var blocking: [WorkItem] = []

    init(
        uuid: UUID = UUID(),
        title: String = "",
        details: String = "",
        priority: Priority = .normal,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        owner: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        completedAt: Date? = nil,
        sortOrder: Double = 0,
        githubIssueNumber: Int? = nil,
        githubRepoSlug: String? = nil
    ) {
        self.uuid = uuid
        self.title = title
        self.details = details
        self.priorityRaw = priority.rawValue
        self.startDate = startDate
        self.dueDate = dueDate
        self.owner = owner
        self.tags = tags
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.githubIssueNumber = githubIssueNumber
        self.githubRepoSlug = githubRepoSlug
        self.subtasks = []
    }

    /// Whether the link still points at the repository this project is linked
    /// to. A project relinked elsewhere leaves stale numbers behind, and
    /// following one would open a completely unrelated issue.
    var hasResolvableIssueLink: Bool {
        guard githubIssueNumber != nil, let slug = githubRepoSlug else { return false }
        return slug == project?.repoSlug
    }

    var githubIssueURL: URL? {
        guard hasResolvableIssueLink,
              let number = githubIssueNumber,
              let slug = githubRepoSlug
        else { return nil }
        return URL(string: "https://github.com/\(slug)/issues/\(number)")
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var project: Project? { column?.project }

    var isDone: Bool { completedAt != nil }

    /// Live subtasks, in order.
    ///
    /// Filters `isDeleted` for the same reason `BoardColumn.orderedItems` does:
    /// a deleted subtask stays in the relationship until the context saves, and
    /// until then it is drawn in the checklist and counted in "2 of 5".
    var orderedSubtasks: [Subtask] {
        subtasks.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var subtaskCount: Int { orderedSubtasks.count }

    var completedSubtaskCount: Int { orderedSubtasks.count(where: \.isDone) }

    // MARK: - Dependency helpers

    /// Blockers that are not yet done — the ones actually holding this up.
    ///
    /// A deleted blocker is not a blocker. Without the `isDeleted` filter a card
    /// stays greyed as **Blocked** with *Send to Claude* disabled, and nothing on
    /// screen explains why, because the blocking card is no longer on the board.
    var openBlockers: [WorkItem] {
        blockedBy.filter { !$0.isDeleted && !$0.isDone }
    }

    var isBlocked: Bool { !openBlockers.isEmpty }

    /// Every card this one blocks, directly or transitively. Used to keep the
    /// dependency graph acyclic when offering new blockers.
    private func blocksTransitively() -> Set<UUID> {
        var seen: Set<UUID> = []
        var stack = blocking
        while let next = stack.popLast() {
            guard seen.insert(next.uuid).inserted else { continue }
            stack.append(contentsOf: next.blocking)
        }
        return seen
    }

    /// Whether `candidate` can become a blocker without forming a cycle or a
    /// duplicate. A card cannot block itself, something already blocking it, or
    /// anything downstream of it.
    func canBeBlocked(by candidate: WorkItem) -> Bool {
        candidate.uuid != uuid
            && !blockedBy.contains { $0.uuid == candidate.uuid }
            && !blocksTransitively().contains(candidate.uuid)
    }

    var isOverdue: Bool {
        guard let dueDate, !isDone else { return false }
        return dueDate < .now
    }

    /// Due within the next two days (and not already overdue or done).
    var isDueSoon: Bool {
        guard let dueDate, !isDone, dueDate >= .now else { return false }
        guard let days = DateHelpers.wholeDays(from: .now, to: dueDate) else { return false }
        return days <= 2
    }

    /// Case-insensitive match across the fields worth searching.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if title.lowercased().contains(needle) { return true }
        if details.lowercased().contains(needle) { return true }
        if owner.lowercased().contains(needle) { return true }
        return tags.contains { $0.lowercased().contains(needle) }
    }
}
