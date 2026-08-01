//
//  Project.swift
//  workflow-manager
//

import Foundation
import SwiftData

@Model
final class Project {
    var uuid: UUID = UUID()
    var name: String = ""
    /// Short description shown in the sidebar and header.
    var summary: String = ""
    var goal: String = ""
    /// Long-form plan / approach.
    var plan: String = ""
    var startDate: Date = Date.now
    var targetEndDate: Date?
    var statusRaw: String = ProjectStatus.planning.rawValue
    var accentRaw: String = ProjectAccent.blue.rawValue
    var symbolName: String = "square.stack.3d.up"
    var createdAt: Date = Date.now
    var sortOrder: Double = 0

    // MARK: - Linked GitHub repository
    //
    // A project can point at a local clone. Nothing about the repository is
    // owned here — these are just enough to find the working copy and label it.
    // Issues themselves are never persisted: GitHub is the source of truth and
    // they are fetched fresh through `gh`.
    //
    // All optional with defaults, which keeps this a lightweight SwiftData
    // migration for anyone with an existing store.

    /// Absolute path to a directory containing `.git`.
    var repoPath: String?
    var repoOwner: String?
    var repoName: String?
    var repoDefaultBranch: String?

    /// Whether this project mirrors its board into `.taskboard/tasks.json` and
    /// applies what a Claude session writes back.
    ///
    /// Off by default, and deliberately so: enabling it means writing files into
    /// the user's repository and letting an agent move their cards. That is a
    /// decision to make, not a default to discover.
    var workflowSyncEnabled: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \BoardColumn.project)
    var columns: [BoardColumn] = []

    /// Commands the Terminal view can start for this project.
    @Relationship(deleteRule: .cascade, inverse: \TerminalCommand.project)
    var terminalCommands: [TerminalCommand] = []

    init(
        uuid: UUID = UUID(),
        name: String = "",
        summary: String = "",
        goal: String = "",
        plan: String = "",
        startDate: Date = .now,
        targetEndDate: Date? = nil,
        status: ProjectStatus = .planning,
        accent: ProjectAccent = .blue,
        symbolName: String = "square.stack.3d.up",
        createdAt: Date = .now,
        sortOrder: Double = 0
    ) {
        self.uuid = uuid
        self.name = name
        self.summary = summary
        self.goal = goal
        self.plan = plan
        self.startDate = startDate
        self.targetEndDate = targetEndDate
        self.statusRaw = status.rawValue
        self.accentRaw = accent.rawValue
        self.symbolName = symbolName
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.columns = []
    }

    // MARK: - Raw-value bridges

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .planning }
        set { statusRaw = newValue.rawValue }
    }

    var accent: ProjectAccent {
        get { ProjectAccent(rawValue: accentRaw) ?? .blue }
        set { accentRaw = newValue.rawValue }
    }

    // MARK: - Derived (never persisted)

    /// The canonical form of a repository path.
    ///
    /// `repoPath` is compared for equality to tell whether a folder is already
    /// open, so it must be stored one way only. A directory `URL` renders its
    /// path with a trailing slash, which would otherwise leak in and make two
    /// spellings of the same folder look different.
    static func canonicalRepoPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `owner/name`, once the repository has been resolved through `gh`.
    var repoSlug: String? {
        guard let repoOwner, let repoName else { return nil }
        return "\(repoOwner)/\(repoName)"
    }

    var repoDirectory: URL? {
        repoPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    var hasRepository: Bool { repoPath != nil }

    /// Live columns, in board order. See `BoardColumn.orderedItems` for why
    /// `isDeleted` is filtered in the accessor rather than at each call site.
    var orderedColumns: [BoardColumn] {
        columns.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var orderedTerminalCommands: [TerminalCommand] {
        terminalCommands.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Every live card on the board. Goes through the ordered accessors so it
    /// inherits their `isDeleted` filtering.
    var allItems: [WorkItem] {
        orderedColumns.flatMap(\.orderedItems)
    }

    // MARK: - Claude sync mapping

    func column(for role: ColumnRole) -> BoardColumn? {
        orderedColumns.first { $0.role == role }
    }

    /// Which status a card in `column` reports.
    ///
    /// A column with no role of its own inherits the nearest role to its left,
    /// so an extra column like "Backlog" or "Blocked" still maps somewhere
    /// sensible instead of hiding its cards from the agent entirely.
    func status(for column: BoardColumn) -> WorkflowTasksFile.Status {
        var inherited: ColumnRole = .todo
        for candidate in orderedColumns {
            if let role = candidate.role { inherited = role }
            if candidate.uuid == column.uuid { break }
        }
        return (column.role ?? inherited).status
    }

    /// Syncing needs somewhere to put an `in_progress` card. Without at least
    /// one role the mapping has no anchor, so the UI asks rather than silently
    /// doing nothing.
    var hasSyncRoles: Bool {
        columns.contains { $0.role != nil }
    }

    var isSyncing: Bool {
        workflowSyncEnabled && hasRepository && hasSyncRoles
    }

    var completedCount: Int {
        columns.filter(\.isCompletionColumn).reduce(0) { $0 + $1.items.count }
    }

    var totalCount: Int { allItems.count }

    var openCount: Int { totalCount - completedCount }

    var overdueCount: Int { allItems.count(where: \.isOverdue) }

    /// Fraction of work items sitting in a completion column, 0...1.
    var progress: Double {
        totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
    }

    /// Fraction of the planned window that has elapsed, 0...1.
    /// `nil` when the project has no target end date to measure against.
    var timeElapsed: Double? {
        guard let targetEndDate else { return nil }
        let total = targetEndDate.timeIntervalSince(startDate)
        guard total > 0 else { return Date.now >= targetEndDate ? 1 : 0 }
        let done = Date.now.timeIntervalSince(startDate)
        return min(max(done / total, 0), 1)
    }

    /// Whole days from today to the target end date. Negative when overdue.
    var daysRemaining: Int? {
        guard let targetEndDate else { return nil }
        return DateHelpers.wholeDays(from: .now, to: targetEndDate)
    }

    var isBehindSchedule: Bool {
        guard let timeElapsed, totalCount > 0 else { return false }
        return progress + 0.05 < timeElapsed
    }

    /// Roughly how many items the project is behind its own burn rate.
    var itemsBehind: Int {
        guard let timeElapsed, totalCount > 0 else { return 0 }
        let expected = timeElapsed * Double(totalCount)
        return max(0, Int((expected - Double(completedCount)).rounded()))
    }
}
