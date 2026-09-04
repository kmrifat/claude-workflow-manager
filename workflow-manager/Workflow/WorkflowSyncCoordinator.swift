//
//  WorkflowSyncCoordinator.swift
//  workflow-manager
//
//  Owns one `WorkflowSyncModel` per syncing project, for the whole life of the
//  app rather than the life of a view.
//
//  ## The bug this exists to fix
//
//  Sync used to be driven entirely by `ProjectDetailView`: `.task(id:)` started
//  it, `.onDisappear` stopped it, and `.onChange(of: boardRevision)` scheduled
//  the write. A project you were not looking at was therefore not synced at all
//  — not merely un-written.
//
//  That was invisible while the only way to change a board was to be looking at
//  it. It stops being invisible the moment anything else can: a phone can mutate
//  a project that is not on screen, and the card would move in SwiftData while
//  `.taskboard/tasks.json` never changed. A Claude session reading that file
//  would never see the work.
//
//  ## What drives it now
//
//  `ModelContext.didSave`. Every path that changes a board ends in a save —
//  a drag, the inspector, quick-add, a phone, an agent's merge being applied —
//  so one observer catches all of them, exactly as `boardRevision` was chosen
//  over calling out from each `BoardMutations` call site. Revisions are compared
//  per project so an unrelated save costs a hash and nothing else.
//
//  Autosave means this fires often. That is fine: the write is coalesced on
//  `WorkflowSyncModel`'s existing debounce, and an unchanged revision does not
//  schedule one at all.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class WorkflowSyncCoordinator {
    /// One engine per project, keyed by uuid. Created when a project starts
    /// syncing and torn down when it stops.
    private var models: [UUID: WorkflowSyncModel] = [:]
    private var revisions: [UUID: Int] = [:]

    private var context: ModelContext?
    private var saveObserver: (any NSObjectProtocol)?

    /// Called after a project's board changes, whoever changed it. The phone
    /// server uses this to push an `event` to connected clients.
    var onBoardChanged: ((Project) -> Void)?

    // MARK: - Lifecycle

    func start(context: ModelContext) {
        guard saveObserver == nil else { return }
        self.context = context

        // Before anything else, and before the observer is installed so the
        // save below cannot re-enter `reconcile`.
        backfillSyncRoles(in: context)

        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` already guarantees the main thread; this is the
            // compiler's proof of it, not a hop.
            MainActor.assumeIsolated { self?.reconcile() }
        }

        reconcile()
    }

    func stop() {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        for model in models.values { model.stop() }
        models.removeAll()
        revisions.removeAll()
        context = nil
    }

    /// The engine for a project, if it is syncing. Subviews read this out of the
    /// environment and show its status; `nil` simply means sync is off.
    func model(for project: Project) -> WorkflowSyncModel? {
        models[project.uuid]
    }

    // MARK: - Back-fill

    /// Rescues boards that have sync turned on and cannot sync.
    ///
    /// `isSyncing` needs at least one column carrying a `ColumnRole`, and boards
    /// created before `defaultColumnSpecs` carried roles have none. The symptom
    /// is the worst kind: the toggle reads as on, the file exists, an agent
    /// writes to it, and nothing ever moves.
    ///
    /// Only projects the user has already opted in are touched, and
    /// `adoptDefaultRoles` refuses any board that has a role of its own.
    private func backfillSyncRoles(in context: ModelContext) {
        let projects = ((try? context.fetch(FetchDescriptor<Project>())) ?? [])
            .filter { !$0.isDeleted && $0.workflowSyncEnabled && $0.hasRepository }

        // Not the user's edit, so ⌘Z must not undo it. The save has to happen
        // inside the disabled window — SwiftData registers undo at save time,
        // not at mutation time.
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            try? context.save()
            undoManager?.enableUndoRegistration()
        }

        for project in projects {
            BoardMutations.adoptDefaultRoles(for: project)
        }
    }

    // MARK: - Reconciliation

    /// Brings the set of running engines in line with the set of syncing
    /// projects, then writes out any board that moved.
    func reconcile() {
        guard let context else { return }

        let projects = ((try? context.fetch(FetchDescriptor<Project>())) ?? [])
            .filter { !$0.isDeleted }
        let syncing = projects.filter { $0.isSyncing && $0.repoDirectory != nil }
        let wanted = Set(syncing.map(\.uuid))

        // Projects that stopped syncing, or were deleted, or had their
        // repository unlinked.
        for (uuid, model) in models where !wanted.contains(uuid) {
            model.stop()
            models[uuid] = nil
            revisions[uuid] = nil
        }

        for project in syncing {
            let model = models[project.uuid] ?? {
                let created = WorkflowSyncModel()
                models[project.uuid] = created
                return created
            }()
            // Idempotent: returns immediately if it is already watching this
            // project. Repeating it also recovers a watcher that stopped
            // because the repository directory was replaced by a checkout.
            model.start(for: project, context: context)
        }

        // Change detection covers **every** project, not just the syncing ones.
        // File sync and phone access are separately switchable, and a phone can
        // open a board that has no repository at all — tracking only `syncing`
        // here would leave those boards silently frozen on the phone.
        //
        // `BoardSnapshotBuilder.revision` rather than the engine's
        // `boardRevision`, which returns 0 unless the project is syncing.
        for project in projects {
            let revision = BoardSnapshotBuilder.revision(of: project)
            guard revisions[project.uuid] != revision else { continue }
            let isFirstSighting = revisions[project.uuid] == nil
            revisions[project.uuid] = revision

            if let model = models[project.uuid] {
                model.scheduleWrite(for: project, context: context)
            }
            // A board seen for the first time has not *changed*; announcing it
            // would make every launch look like a flurry of edits to a
            // connected phone.
            if !isFirstSighting { onBoardChanged?(project) }
        }

        // Forget projects that are gone, so their uuids cannot read as
        // "first sighting" again if one is somehow reinstated.
        let known = Set(projects.map(\.uuid))
        revisions = revisions.filter { known.contains($0.key) }
    }

    /// For a caller that has just mutated a board and does not want to wait for
    /// the next autosave — the phone, which has a user watching a spinner.
    func boardChanged(_ project: Project) {
        let revision = BoardSnapshotBuilder.revision(of: project)
        // Already announced. This is not a rare race: `ModelContext.didSave` is
        // delivered *synchronously* on the posting thread, so a phone mutation's
        // own `context.save()` runs `reconcile` before the caller here gets a
        // turn — and the board would be announced twice for one edit.
        //
        // Deduplicating on the revision rather than ordering the two callers
        // makes it symmetric: whoever notices a change first announces it, and
        // the other finds nothing to do.
        guard revisions[project.uuid] != revision else { return }
        revisions[project.uuid] = revision

        if let context, let model = models[project.uuid] {
            model.scheduleWrite(for: project, context: context)
        }
        // Announced even when the project syncs to no file: phone access does
        // not require a linked repository.
        onBoardChanged?(project)
    }
}
