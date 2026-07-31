//
//  GitHubIssuesModel.swift
//  workflow-manager
//
//  Holds the fetched issues for one project, backed by `IssueCache` so the board
//  paints from the last fetch instead of a spinner. GitHub is still the source
//  of truth — the cache is timestamped, disposable, and replaced wholesale.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class GitHubIssuesModel {
    enum State {
        case idle
        case loading
        case loaded([GitHubIssue], fetchedAt: Date)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// A refresh that failed while issues were already on screen. Distinct from
    /// `.failed`, which means there is nothing to show at all: losing a usable
    /// board because one `gh` call timed out would be worse than stale data.
    private(set) var refreshError: String?

    /// True while refetching over contents that are already displayed.
    private(set) var isRefreshing = false

    /// The repo the current contents belong to, so switching projects doesn't
    /// briefly show another project's issues.
    private var loadedPath: String?

    var issues: [GitHubIssue] {
        if case .loaded(let issues, _) = state { return issues }
        return []
    }

    var fetchedAt: Date? {
        if case .loaded(_, let at) = state { return at }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return isRefreshing
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Whether what we are showing has aged past `IssueCache.ttl`.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date.now.timeIntervalSince(fetchedAt) > IssueCache.ttl
    }

    /// Paints from the cache, then fetches only if there was nothing cached or
    /// what was cached has expired.
    func loadIfNeeded(for project: Project, in context: ModelContext) async {
        guard let path = project.repoPath else {
            state = .idle
            loadedPath = nil
            return
        }

        if path == loadedPath, !isIdle, !isStale { return }

        if path != loadedPath || isIdle,
           let hit = await IssueCache.load(for: project, in: context) {
            state = .loaded(hit.issues, fetchedAt: hit.fetchedAt)
            loadedPath = path
            refreshError = nil
            guard hit.isStale else { return }
        }

        await reload(for: project, in: context)
    }

    func reload(for project: Project, in context: ModelContext) async {
        guard let directory = project.repoDirectory else {
            state = .idle
            return
        }

        // Only blank the board when there is nothing worth keeping on it.
        let hasContents = !issues.isEmpty
        if hasContents {
            isRefreshing = true
        } else {
            state = .loading
        }
        defer { isRefreshing = false }

        do {
            let issues = try await GitHubCLI.openIssues(at: directory)
            state = .loaded(issues, fetchedAt: .now)
            loadedPath = project.repoPath
            refreshError = nil
            await IssueCache.store(issues, for: project, in: context)
        } catch {
            if hasContents {
                refreshError = error.localizedDescription
            } else {
                state = .failed(error.localizedDescription)
            }
            loadedPath = project.repoPath
        }
    }

    /// Clears everything — used when a project is disconnected from its repo.
    func reset() {
        state = .idle
        loadedPath = nil
        refreshError = nil
        isRefreshing = false
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }
}
