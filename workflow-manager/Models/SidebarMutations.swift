//
//  SidebarMutations.swift
//  workflow-manager
//
//  Every change to the sidebar tree goes through here, for the same reason
//  board changes go through `BoardMutations`: the invariants live in one place.
//  Two matter —
//
//  - **Deleting a folder never deletes a project.** Its projects and subfolders
//    move up to its parent first; a deleted workspace leaves them unfiled.
//  - **The tree stays a tree.** A folder cannot move into itself or anything
//    beneath it.
//

import Foundation
import SwiftData

@MainActor
enum SidebarMutations {

    // MARK: - Folders

    @discardableResult
    static func createFolder(
        named name: String,
        in parent: ProjectFolder?,
        context: ModelContext
    ) -> ProjectFolder {
        let siblings = parent?.orderedChildren ?? workspaces(in: context)
        let folder = ProjectFolder(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: FractionalOrder.afterLast(of: siblings.map(\.sortOrder)),
            parent: parent
        )
        context.insert(folder)
        return folder
    }

    /// Re-homes everything inside `folder` one level up, then deletes it.
    static func delete(_ folder: ProjectFolder, context: ModelContext) {
        let destination = folder.parent
        for project in folder.orderedProjects {
            project.folder = destination
        }
        for child in folder.orderedChildren {
            child.parent = destination
        }
        context.delete(folder)
    }

    /// Moves `folder` under `newParent` (`nil` makes it a workspace).
    /// Returns false, and changes nothing, if that would create a cycle.
    @discardableResult
    static func move(_ folder: ProjectFolder, into newParent: ProjectFolder?, context: ModelContext) -> Bool {
        if let newParent, folder.contains(newParent) { return false }
        guard folder.parent?.uuid != newParent?.uuid else { return true }
        let siblings = newParent?.orderedChildren ?? workspaces(in: context)
        folder.sortOrder = FractionalOrder.afterLast(of: siblings.map(\.sortOrder))
        folder.parent = newParent
        return true
    }

    // MARK: - Projects

    /// Files `project` at the end of `folder` (`nil` = unfiled).
    static func move(_ project: Project, into folder: ProjectFolder?, siblings: [Project]) {
        guard project.folder?.uuid != folder?.uuid else { return }
        project.sortOrder = FractionalOrder.afterLast(of: siblings.map(\.sortOrder))
        project.folder = folder
    }

    /// Puts `dragged` immediately before `target`, adopting `target`'s folder.
    /// Re-spaces that folder's order, which only has to be consistent within it.
    static func move(_ dragged: Project, before target: Project, siblings: [Project]) {
        guard dragged.uuid != target.uuid else { return }
        var ordered = siblings.filter { $0.uuid != dragged.uuid }
        guard let index = ordered.firstIndex(where: { $0.uuid == target.uuid }) else { return }
        ordered.insert(dragged, at: index)
        dragged.folder = target.folder
        for (project, order) in zip(ordered, FractionalOrder.normalizedOrders(count: ordered.count)) {
            project.sortOrder = order
        }
    }

    // MARK: - Queries

    static func workspaces(in context: ModelContext) -> [ProjectFolder] {
        let descriptor = FetchDescriptor<ProjectFolder>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.parent == nil && !$0.isDeleted }
    }

    // MARK: - Migration

    /// Turns the old flat `groupName` into workspaces, once.
    ///
    /// Each distinct name becomes a workspace (matched case-insensitively, so
    /// "ACME CORP" and "Acme Corp" do not become two), the project moves into it,
    /// and `groupName` is cleared so this never runs for that project again.
    /// Runs with undo disabled and saves inside that window: SwiftData registers
    /// undo at save time, and ⌘Z must not un-migrate someone's sidebar.
    static func adoptLegacyGroups(in context: ModelContext) {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let legacy = projects.filter { project in
            project.folder == nil && !(project.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !legacy.isEmpty else { return }

        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        var byName: [String: ProjectFolder] = [:]
        for workspace in workspaces(in: context) {
            byName[workspace.name.lowercased()] = workspace
        }
        for project in legacy.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let raw = (project.groupName ?? "").trimmingCharacters(in: .whitespaces)
            let key = raw.lowercased()
            let workspace = byName[key] ?? {
                let created = createFolder(named: displayName(forLegacy: raw), in: nil, context: context)
                byName[key] = created
                return created
            }()
            project.folder = workspace
            project.groupName = nil
        }
        try? context.save()
    }

    /// Old group names were typed freely and drawn uppercased, so many were
    /// entered in capitals. "ACME CORP" reads as shouting in a section header
    /// that now keeps its case; "Acme Corp" does not. Mixed case is left alone —
    /// that was deliberate.
    static func displayName(forLegacy raw: String) -> String {
        guard raw == raw.uppercased(), raw.contains(where: \.isLetter) else { return raw }
        return raw.lowercased().capitalized
    }
}
