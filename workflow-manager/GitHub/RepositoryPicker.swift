//
//  RepositoryPicker.swift
//  workflow-manager
//
//  Choosing the working copy a project is about.
//
//  The app is not sandboxed, so a plain path is enough — no security-scoped
//  bookmark to resolve on every launch.
//

import AppKit
import Foundation

@MainActor
enum RepositoryPicker {
    /// Presents an open panel limited to directories.
    /// Returns `nil` if the user cancels.
    static func chooseDirectory(startingAt current: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder containing this project’s Git repository."
        panel.directoryURL = current

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Picks a directory, checks it is a clone, and resolves it through `gh`.
    ///
    /// Resolving here rather than at first fetch means a folder with no GitHub
    /// remote is rejected while the user is still looking at the picker, instead
    /// of turning into an empty board later.
    static func connect(to project: Project, startingAt current: URL? = nil) async throws {
        guard let directory = chooseDirectory(startingAt: current) else { return }

        try GitHubCLI.validateGitDirectory(directory)
        let repository = try await GitHubCLI.repository(at: directory)

        project.repoPath = Project.canonicalRepoPath(directory)
        project.repoOwner = repository.owner
        project.repoName = repository.name
        project.repoDefaultBranch = repository.defaultBranch
    }
}
