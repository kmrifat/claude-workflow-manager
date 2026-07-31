//
//  TerminalCommand.swift
//  workflow-manager
//
//  A command saved against a project, so the several processes a project needs
//  running can be started together instead of remembered.
//
//  The directory is stored *relative to the repository*, not absolute: a clone
//  moved or re-cloned somewhere else keeps working, and the saved commands stay
//  meaningful if the project is relinked.
//

import Foundation
import SwiftData

@Model
final class TerminalCommand {
    var uuid: UUID = UUID()
    /// What to show in the list. Falls back to the command itself when blank.
    var name: String = ""
    /// A shell line, run by the user's login shell. Not an argument array —
    /// these are things people type, pipes and `&&` included.
    var command: String = ""
    /// Relative to the project's repository. Empty means the repository root.
    var directory: String = ""
    var sortOrder: Double = 0
    /// Whether "Run All" includes this one. Off is how you keep a command
    /// around without starting it every time.
    var isIncludedInRunAll: Bool = true

    var project: Project?

    init(
        uuid: UUID = UUID(),
        name: String = "",
        command: String = "",
        directory: String = "",
        sortOrder: Double = 0,
        isIncludedInRunAll: Bool = true
    ) {
        self.uuid = uuid
        self.name = name
        self.command = command
        self.directory = directory
        self.sortOrder = sortOrder
        self.isIncludedInRunAll = isIncludedInRunAll
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command : trimmed
    }

    /// Where this command runs, resolved against the project's repository.
    ///
    /// Returns `nil` when the relative path escapes the repository — a saved
    /// `../../` should not become a way to run commands anywhere on the disk.
    func resolvedDirectory(in project: Project) -> URL? {
        guard let root = project.repoDirectory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return root }

        let resolved = root.appending(path: trimmed).standardizedFileURL
        guard Self.path(resolved, isInside: root) else { return nil }
        return resolved
    }

    /// Whether `candidate` is `root` or lives under it.
    ///
    /// Trailing slashes have to go before comparing: a directory URL renders
    /// its path as `…/repo/`, so a naive `hasPrefix(rootPath + "/")` tests for
    /// `…/repo//` and is false for *every* subfolder. That failure is silent —
    /// it looks exactly like the path-escape rejection it is meant to be.
    static func path(_ candidate: URL, isInside root: URL) -> Bool {
        let rootPath = normalized(root)
        let candidatePath = normalized(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
