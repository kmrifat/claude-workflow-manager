//
//  RepositoryStatusModel.swift
//  workflow-manager
//
//  Local git state for the linked repository: which branch is checked out, and
//  what work sits on each issue's branch.
//
//  Summaries are cached briefly — the board asks for one per visible card, and
//  shelling out to git on every redraw would be absurd.
//

import Foundation
import Observation

@MainActor
@Observable
final class RepositoryStatusModel {
    private(set) var currentBranch: String?
    private(set) var hasUncommittedChanges = false
    private(set) var branches: [String] = []
    /// Keyed by issue number.
    private(set) var summaries: [Int: GitReader.BranchSummary] = [:]
    private(set) var errorMessage: String?

    /// Matches the build plan's git-summary TTL.
    private static let cacheLifetime: TimeInterval = 30
    private var loadedAt: Date?
    private var loadedPath: String?

    var isStale: Bool {
        guard let loadedAt else { return true }
        return Date().timeIntervalSince(loadedAt) > Self.cacheLifetime
    }

    func summary(forIssue number: Int) -> GitReader.BranchSummary? {
        summaries[number]
    }

    /// Refreshes only when the cache has expired or the repository changed.
    func loadIfNeeded(for project: Project, issues: [GitHubIssue]) async {
        guard project.repoPath != loadedPath || isStale else { return }
        await reload(for: project, issues: issues)
    }

    func reload(for project: Project, issues: [GitHubIssue]) async {
        guard let directory = project.repoDirectory else {
            reset()
            return
        }

        do {
            let branches = try await GitReader.localBranches(at: directory)
            let current = try await GitReader.currentBranch(at: directory)
            let dirty = try await GitReader.hasUncommittedChanges(at: directory)
            let base = project.repoDefaultBranch ?? "main"

            // Only issues that actually have a branch cost a git call.
            var found: [Int: GitReader.BranchSummary] = [:]
            for issue in issues {
                guard let branch = IssueBranchMatcher.branch(forIssue: issue.number, among: branches)
                else { continue }
                // One bad branch must not lose the whole board's git state.
                if let summary = try? await GitReader.summary(at: directory, branch: branch, base: base) {
                    found[issue.number] = summary
                }
            }

            self.branches = branches
            currentBranch = current
            hasUncommittedChanges = dirty
            summaries = found
            errorMessage = nil
            loadedAt = Date()
            loadedPath = project.repoPath
        } catch {
            errorMessage = error.localizedDescription
            loadedAt = Date()
            loadedPath = project.repoPath
        }
    }

    func reset() {
        currentBranch = nil
        hasUncommittedChanges = false
        branches = []
        summaries = [:]
        errorMessage = nil
        loadedAt = nil
        loadedPath = nil
    }
}
