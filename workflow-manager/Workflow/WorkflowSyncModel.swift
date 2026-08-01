//
//  WorkflowSyncModel.swift
//  workflow-manager
//
//  Keeps one project's board and its `.taskboard/tasks.json` in step.
//
//  ## Concurrency
//
//  Watching, hashing, decoding, encoding, merging and file I/O are all
//  `nonisolated` and happen off the main actor. Every SwiftData read and write
//  happens here, on the main actor, in `apply` and `writeNow`. The only things
//  that cross that line are `Sendable` value types — `Data`, `Envelope`,
//  `TaskRow`, `Plan`. No model object and no `ModelContext` ever leaves the main
//  actor.
//

import Foundation
import Observation
import SwiftData
import ClaudeWMWire

@MainActor
@Observable
final class WorkflowSyncModel {
    /// Set when the file was written by a newer version of the format. Nothing
    /// is read from it and nothing is written to it while this holds.
    private(set) var incompatibleFile = false
    /// Set when the file could not be parsed. The board keeps its last good
    /// state rather than being cleared by a half-written file.
    private(set) var parseError: String?
    private(set) var lastWriteAt: Date?
    private(set) var isRunning = false

    private var watcher: WorkflowFileWatcher?
    private var consumeTask: Task<Void, Never>?
    private var pendingWrite: Task<Void, Never>?
    private var projectUUID: UUID?

    /// Cards deleted locally, so an agent holding stale state cannot resurrect
    /// them. In memory only: a tombstone that outlived the session has already
    /// done its job, because the file no longer lists the row either.
    private var tombstones: [WorkflowTasksFile.Tombstone] = []

    /// The ids in the last envelope this app wrote.
    ///
    /// Deletions are *derived* by diffing this against the board, rather than
    /// reported by whoever deleted the card. There are four places a work item
    /// can be deleted from — the inspector, a card's context menu, the table,
    /// and the ⌘⌫ command — and a fifth will appear eventually. Diffing catches
    /// all of them and cannot be forgotten at a new call site.
    private var lastWrittenIDs: Set<String> = []

    /// `WorkItemEditorSheet` mutates on every keystroke. Coalescing avoids
    /// rewriting the file twenty times while someone types a title.
    private static let writeDebounce: Duration = .milliseconds(1500)

    // MARK: - Lifecycle

    func start(for project: Project, context: ModelContext) {
        guard project.isSyncing, let repository = project.repoDirectory else {
            stop()
            return
        }
        // Already watching this project.
        if isRunning, projectUUID == project.uuid { return }
        stop()

        do {
            try WorkflowDirectory.ensure(in: repository)
        } catch {
            parseError = error.localizedDescription
            return
        }

        projectUUID = project.uuid
        isRunning = true

        let watcher = WorkflowFileWatcher(directory: WorkflowDirectory.url(in: repository))
        self.watcher = watcher
        watcher.start()

        consumeTask = Task { [weak self] in
            for await data in watcher.changes {
                guard let self else { return }
                await self.ingest(data, for: project, context: context)
            }
        }

        // Seed the file, and pick up anything already in it.
        Task { [weak self] in
            await self?.bootstrap(for: project, context: context)
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        watcher?.stop()
        watcher = nil
        projectUUID = nil
        isRunning = false
    }

    /// A hash of everything that would appear in the file.
    ///
    /// Observing this rather than calling out from `BoardMutations` catches
    /// every path that can change the board — a drag, the inspector, quick-add,
    /// even a merge we just applied — without each of them having to know the
    /// sync exists. Re-applying our own change simply produces an identical
    /// write, which echo suppression then drops.
    func boardRevision(of project: Project) -> Int {
        guard project.isSyncing else { return 0 }
        var hasher = Hasher()
        for column in project.orderedColumns {
            hasher.combine(column.name)
            hasher.combine(column.roleRaw)
            // Same reason as `snapshot`: a deleted item lingers here until the
            // context saves, and the revision has to change *now* so the write
            // that records the tombstone is actually scheduled.
            for item in column.orderedItems {
                hasher.combine(item.uuid)
                hasher.combine(item.title)
                hasher.combine(item.details)
                hasher.combine(item.githubIssueNumber)
                hasher.combine(item.workflowRequested)
                hasher.combine(item.workflowBranch)
                hasher.combine(item.workflowPRURL)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Writing

    /// Coalesced write. Safe to call on every board edit.
    func scheduleWrite(for project: Project, context: ModelContext) {
        guard isRunning, project.isSyncing else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDebounce)
            guard !Task.isCancelled else { return }
            await self?.writeNow(for: project, context: context)
        }
    }

    /// Writes immediately — used when the user sends a card to Claude, and just
    /// before starting a session, where a debounce would be a race.
    func writeNow(for project: Project, context: ModelContext) async {
        guard project.isSyncing,
              let repository = project.repoDirectory,
              !incompatibleFile
        else { return }

        let local = snapshot(of: project)
        recordDeletions(against: local)

        let envelope = WorkflowMerge.envelope(
            local: local,
            project: reference(to: project),
            tombstones: tombstones,
            now: .now
        )
        await write(envelope, to: repository)
    }

    /// Anything this app previously wrote that the board no longer has was
    /// deleted locally, whichever screen did it.
    private func recordDeletions(against local: [WorkflowMerge.LocalTask]) {
        let current = Set(local.map(\.id))
        let removed = lastWrittenIDs.subtracting(current)
        if !removed.isEmpty {
            let now = Date.now
            tombstones.append(
                contentsOf: removed.map {
                    WorkflowTasksFile.Tombstone(id: $0, deletedAt: now)
                }
            )
            tombstones = WorkflowTasksFile.pruningTombstones(tombstones, now: now)
        }
        lastWrittenIDs = current
    }

    private func write(_ envelope: WorkflowTasksFile.Envelope, to repository: URL) async {
        let url = WorkflowDirectory.tasksURL(in: repository)
        let written = await Task.detached { () -> Data? in
            try? WorkflowTasksFile.write(envelope, to: url)
        }.value

        guard let written else { return }
        // Teach the watcher to ignore the change it is about to see.
        watcher?.suppressEcho(of: written)
        lastWriteAt = .now
    }

    // MARK: - Reading

    private func bootstrap(for project: Project, context: ModelContext) async {
        guard let repository = project.repoDirectory else { return }
        let url = WorkflowDirectory.tasksURL(in: repository)

        if let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value {
            await ingest(data, for: project, context: context)
        } else {
            await writeNow(for: project, context: context)
        }
    }

    private func ingest(_ data: Data, for project: Project, context: ModelContext) async {
        let local = snapshot(of: project)
        let reference = reference(to: project)
        let existingTombstones = tombstones

        // Decode and merge off the main actor: both are pure, and neither needs
        // to hold up the UI.
        let outcome = await Task.detached {
            () -> Result<WorkflowMerge.Plan, any Error> in
            do {
                var incoming = try WorkflowTasksFile.decode(data)
                incoming.tombstones = mergedTombstones(incoming.tombstones, existingTombstones)
                return .success(
                    WorkflowMerge.merge(
                        local: local,
                        incoming: incoming,
                        project: reference,
                        allowCreations: true,
                        now: .now
                    )
                )
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .failure(let error):
            // A half-written file is not a reason to clear someone's board.
            parseError = error.localizedDescription
            return
        case .success(let plan):
            parseError = nil
            guard !plan.rejectedAsNewer else {
                incompatibleFile = true
                return
            }
            incompatibleFile = false
            apply(plan, to: project, context: context)

            if plan.fileNeedsRewrite, let repository = project.repoDirectory {
                await writeNow(for: project, context: context)
                _ = repository
            }
        }
    }

    /// The only place agent-driven changes touch SwiftData.
    private func apply(
        _ plan: WorkflowMerge.Plan,
        to project: Project,
        context: ModelContext
    ) {
        guard !plan.changes.isEmpty || !plan.creations.isEmpty else { return }

        // Not the user's edits. Without this, ⌘Z would undo something an agent
        // did in the background — invisible, and it would desynchronise the
        // board from the file.
        //
        // The `save` in the `defer` is what actually does it. SwiftData
        // registers its undo action when the context *saves*, not when an
        // object is mutated, so disabling registration around the mutation
        // alone changes nothing — the next autosave registers it once the
        // window has closed. Saving before re-enabling is the whole trick.
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            try? context.save()
            undoManager?.enableUndoRegistration()
        }

        let byID = Dictionary(
            project.allItems.map { ($0.uuid.uuidString, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for change in plan.changes {
            guard let item = byID[change.id] else { continue }
            if let branch = change.branch { item.workflowBranch = branch }
            if let prUrl = change.prUrl { item.workflowPRURL = prUrl }
            if let status = change.status,
               let column = project.column(for: ColumnRole(status: status)),
               item.column?.uuid != column.uuid {
                // Read before the move: afterwards there is no record of where
                // it came from, and "Review → Done" is most of what the
                // notification is worth.
                let from = item.column?.name
                BoardMutations.append(item, to: column)
                // The agent picked it up; the request is satisfied.
                if status != .todo { item.workflowRequested = false }

                BoardNotifier.shared.post(CardMoveNotice(
                    cardTitle: item.title,
                    fromColumn: from,
                    toColumn: column.name,
                    projectName: project.name,
                    origin: .claude
                ))
            }
        }

        for row in plan.creations {
            let role = ColumnRole(status: row.status)
            guard let column = project.column(for: role)
                    ?? project.column(for: .todo)
                    ?? project.orderedColumns.first
            else { continue }

            let item = WorkItem(
                uuid: UUID(uuidString: row.id) ?? UUID(),
                title: row.title,
                details: row.details ?? "",
                githubIssueNumber: row.githubIssue,
                githubRepoSlug: row.githubIssue == nil ? nil : project.repoSlug
            )
            item.workflowBranch = row.branch
            item.workflowPRURL = row.prUrl
            context.insert(item)
            BoardMutations.append(item, to: column)
        }
    }

    // MARK: - Snapshots

    /// The board as plain values, safe to hand to a detached task.
    ///
    /// `isDeleted` items are dropped explicitly. SwiftData leaves a deleted
    /// object in its relationship array until the context saves, so without
    /// this a card deleted a moment ago is still written to the file — and an
    /// agent reading it back would recreate the card from our own row.
    private func snapshot(of project: Project) -> [WorkflowMerge.LocalTask] {
        project.orderedColumns.flatMap { column in
            column.orderedItems.map { item in
                WorkflowMerge.LocalTask(
                    id: item.uuid.uuidString,
                    title: item.title,
                    details: item.details,
                    status: project.status(for: column),
                    githubIssue: item.githubIssueNumber,
                    branch: item.workflowBranch,
                    prUrl: item.workflowPRURL,
                    requested: item.workflowRequested,
                    column: column.name,
                    updatedAt: item.completedAt ?? item.createdAt
                )
            }
        }
    }

    private func reference(to project: Project) -> WorkflowTasksFile.ProjectRef {
        WorkflowTasksFile.ProjectRef(
            uuid: project.uuid.uuidString,
            name: project.name,
            repo: project.repoSlug
        )
    }
}

/// Union of what the file remembers and what this session has recorded.
private nonisolated func mergedTombstones(
    _ incoming: [WorkflowTasksFile.Tombstone],
    _ local: [WorkflowTasksFile.Tombstone]
) -> [WorkflowTasksFile.Tombstone] {
    var byID: [String: WorkflowTasksFile.Tombstone] = [:]
    for tombstone in incoming + local {
        if let existing = byID[tombstone.id], existing.deletedAt >= tombstone.deletedAt { continue }
        byID[tombstone.id] = tombstone
    }
    return byID.values.sorted { $0.id < $1.id }
}
