//
//  ProjectFolder.swift
//  workflow-manager
//
//  The sidebar's hierarchy: Workspace › Folder › … › Project.
//
//  One model for both levels. A folder with no parent *is* a workspace — the
//  top-level section the sidebar draws as a header — and any folder can hold
//  more folders, so a workspace is simply the root of a tree. Two models would
//  have meant two relationships on `Project` and a rule that exactly one is set,
//  which is the kind of invariant SwiftData cannot enforce for us.
//
//  Local organisation only, like the `groupName` it replaces: nothing about it
//  syncs, reaches a phone, or is written into a repository.
//

import Foundation
import SwiftData

@Model
final class ProjectFolder {
    var uuid: UUID = UUID()
    var name: String = ""
    var sortOrder: Double = 0

    /// `nil` makes this a workspace.
    var parent: ProjectFolder?

    /// Deleting a folder must never delete projects, and must never orphan
    /// subfolders into nothing — `SidebarMutations.delete` re-homes both before
    /// the delete, and `.nullify` is the safety net if anything is missed: an
    /// orphaned folder becomes a workspace, an orphaned project becomes unfiled.
    @Relationship(deleteRule: .nullify, inverse: \ProjectFolder.parent)
    var children: [ProjectFolder] = []

    @Relationship(deleteRule: .nullify, inverse: \Project.folder)
    var projects: [Project] = []

    init(uuid: UUID = UUID(), name: String = "", sortOrder: Double = 0, parent: ProjectFolder? = nil) {
        self.uuid = uuid
        self.name = name
        self.sortOrder = sortOrder
        self.parent = parent
        self.children = []
        self.projects = []
    }

    var isWorkspace: Bool { parent == nil }

    var displayName: String { name.isEmpty ? "Untitled Folder" : name }

    /// Same reasoning as `BoardColumn.orderedItems`: a deleted object lingers in
    /// its relationship arrays until the context saves.
    var orderedChildren: [ProjectFolder] {
        children.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var orderedProjects: [Project] {
        projects.lazy.filter { !$0.isDeleted }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Every project at or below this folder.
    var allProjects: [Project] {
        orderedProjects + orderedChildren.flatMap(\.allProjects)
    }

    /// Root first, ending with `self`.
    var path: [ProjectFolder] {
        (parent?.path ?? []) + [self]
    }

    /// The workspace this folder lives in.
    var workspace: ProjectFolder { parent?.workspace ?? self }

    /// 0 for a workspace.
    var depth: Int { (parent?.depth ?? -1) + 1 }

    /// Whether `other` is this folder or sits anywhere beneath it. Moving a
    /// folder into one of its own descendants would detach a cycle from the
    /// tree, so every move checks this first.
    func contains(_ other: ProjectFolder) -> Bool {
        var cursor: ProjectFolder? = other
        while let current = cursor {
            if current.uuid == uuid { return true }
            cursor = current.parent
        }
        return false
    }
}
