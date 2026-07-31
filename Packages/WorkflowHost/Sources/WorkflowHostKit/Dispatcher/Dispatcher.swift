import Foundation
import WorkflowCore

/// Decides what runs next, and runs it.
///
/// An actor because it owns real mutable state nothing else serializes:
/// in-flight runs and their child processes. It writes through `RunStore`
/// (GRDB-owned, not actor-isolated) and only ever *sends* to `EventHub` — the
/// actor graph stays acyclic.
///
/// Every run ends at "PR opened". Nothing here merges.
public actor Dispatcher {
    private let config: HostConfig
    private let client: GitHubClient
    private let cache: CacheStore
    private let runs: RunStore
    private let state: StateBuilder
    private let hub: EventHub?
    /// The GitHub login runs are assigned to — the identity that holds the lock.
    private let selfLogin: String
    /// Set false in tests and dry runs; nothing touches GitHub or the filesystem.
    private let isEnabled: Bool

    /// Live children, by run id. The dispatcher is the only owner.
    private var children: [Int64: Process] = [:]

    public init(
        config: HostConfig,
        client: GitHubClient,
        cache: CacheStore,
        runs: RunStore,
        state: StateBuilder,
        selfLogin: String,
        hub: EventHub? = nil,
        isEnabled: Bool = true
    ) {
        self.config = config
        self.client = client
        self.cache = cache
        self.runs = runs
        self.state = state
        self.hub = hub
        self.selfLogin = selfLogin
        self.isEnabled = isEnabled
    }

    // MARK: - Boot

    /// Any run marked `running` whose process is gone died with the host — the
    /// Mac slept, or the app was quit. Recorded as failed so the dashboard stops
    /// claiming work is in flight.
    @discardableResult
    public func reconcile(now: Date = Date()) async -> [Int64] {
        var reconciled: [Int64] = []
        for run in (try? runs.activeRuns()) ?? [] {
            guard !isAlive(run) else { continue }
            try? runs.finish(
                runId: run.id, status: .failed, exitCode: nil,
                event: .failed, detail: "host restarted while this run was live", at: now
            )
            reconciled.append(run.id)
        }
        if !reconciled.isEmpty {
            Log.dispatcher.notice("reconciled \(reconciled.count) dead run(s) on boot")
            await hub?.broadcast()
        }
        return reconciled
    }

    private func isAlive(_ run: RunRecord) -> Bool {
        if children[run.id]?.isRunning == true { return true }
        guard let pid = run.pid else { return false }
        // Signal 0 tests for existence without delivering anything.
        return kill(pid, 0) == 0
    }

    // MARK: - Tick

    /// One pass over every repo. Never throws — the loop must survive a bad repo.
    @discardableResult
    public func tick() async -> [DispatchOutcome] {
        var outcomes: [DispatchOutcome] = []
        let snapshot = await state.build()

        for repo in config.repos {
            guard let repoState = snapshot.repos.first(where: { $0.id == repo.id }) else { continue }
            let active = (try? runs.activeRuns(repo: repo.id)) ?? []

            let decision = DispatchRules.selectNext(
                ready: repoState.readyIssues,
                activeRuns: active,
                maxConcurrentPerRepo: config.maxConcurrentPerRepo
            )

            guard let issue = decision.selected else {
                outcomes.append(.idle(repo: repo.id, skipped: decision.skipped.count))
                continue
            }

            do {
                let runId = try await dispatch(issue: issue, in: repo)
                outcomes.append(.dispatched(repo: repo.id, issue: issue.number, runId: runId))
                await hub?.broadcast()
            } catch {
                Log.dispatcher.error("dispatch failed for \(repo.id)#\(issue.number): \(String(describing: error), privacy: .public)")
                try? runs.recordEvent(
                    runId: nil, kind: .failed,
                    detail: "\(repo.id)#\(issue.number): \(error)"
                )
                outcomes.append(.failed(repo: repo.id, issue: issue.number, reason: String(describing: error)))
            }
        }
        return outcomes
    }

    // MARK: - Dispatch

    /// Claims the issue, prepares a worktree, and starts a session.
    ///
    /// The assignment happens **first and alone**. It is the lock: if two hosts
    /// race, the loser's assign still succeeds (GitHub allows multiple
    /// assignees) but the next poll shows the issue claimed and it backs off.
    /// Doing local work first would mean two worktrees for one issue.
    func dispatch(issue: ReadyIssue, in repo: RepoConfig) async throws -> Int64 {
        guard isEnabled else { throw DispatchError.disabled }

        try await client.assignIssue(
            owner: repo.owner, name: repo.name, number: issue.number, to: selfLogin
        )

        let branch = DispatchRules.branchName(forIssue: issue.number)
        let worktree = DispatchRules.worktreePath(repoPath: repo.path, issue: issue.number)
        let runId = try runs.createRun(
            repo: repo.id, issueNumber: issue.number, area: issue.area,
            branch: branch, worktreePath: worktree
        )

        do {
            try await prepareWorktree(repo: repo, branch: branch, at: worktree)
            let process = try startSession(in: worktree, issue: issue, repo: repo, runId: runId)
            children[runId] = process
            try runs.attachSession(runId: runId, sessionId: nil, pid: process.processIdentifier)
            try? await moveCard(issue: issue, in: repo, to: repo.activeColumn)
            watch(runId: runId, process: process, repo: repo, branch: branch, issue: issue)
            return runId
        } catch {
            // Leave nothing half-claimed: release the issue so another host — or
            // the next tick — can pick it up.
            try? await client.unassignIssue(
                owner: repo.owner, name: repo.name, number: issue.number, from: selfLogin
            )
            try? runs.finish(
                runId: runId, status: .failed, exitCode: nil,
                event: .failed, detail: String(describing: error)
            )
            throw error
        }
    }

    private func prepareWorktree(repo: RepoConfig, branch: String, at path: String) async throws {
        let directory = URL(filePath: repo.path, directoryHint: .isDirectory)
        let base = (try? cache.read(CacheStore.Key.repository(repo), as: RepositoryInfo.self))?
            .value.defaultBranch ?? "main"

        // Fetch first: branching from a stale origin means the run starts from
        // work that moved hours ago.
        try await GitReader.run(["fetch", "origin", "--prune"], in: directory)
        try await GitReader.run(
            ["worktree", "add", "-b", branch, path, "origin/\(base)"],
            in: directory
        )
    }

    private func startSession(
        in worktree: String,
        issue: ReadyIssue,
        repo: RepoConfig,
        runId: Int64
    ) throws -> Process {
        let claude = try ProcessRunner.locate("claude")
        let logDirectory = URL(filePath: worktree, directoryHint: .isDirectory)
            .appending(path: ".workflowhost")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        return try ProcessRunner.spawn(
            executable: claude,
            arguments: ["remote-control", "--spawn", "worktree"],
            workingDirectory: URL(filePath: worktree, directoryHint: .isDirectory),
            standardOutput: logDirectory.appending(path: "run-\(runId).log")
        )
    }

    /// Watches for exit, then finishes the run.
    private func watch(
        runId: Int64,
        process: Process,
        repo: RepoConfig,
        branch: String,
        issue: ReadyIssue
    ) {
        Task { [weak self] in
            // waitUntilExit blocks, so it goes to a detached task.
            let code = await Task.detached { () -> Int32 in
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            await self?.finish(runId: runId, exitCode: code, repo: repo, branch: branch, issue: issue)
        }
    }

    func finish(runId: Int64, exitCode: Int32, repo: RepoConfig, branch: String, issue: ReadyIssue) async {
        children[runId] = nil

        guard exitCode == 0 else {
            try? runs.finish(
                runId: runId, status: .failed, exitCode: exitCode,
                event: .failed, detail: "session exited \(exitCode)"
            )
            await hub?.broadcast()
            return
        }

        do {
            let url = try await openPullRequest(repo: repo, branch: branch, issue: issue)
            try runs.finish(
                runId: runId, status: .review, exitCode: exitCode,
                event: .prOpened, detail: url.absoluteString
            )
            try? await moveCard(issue: issue, in: repo, to: repo.reviewColumn)
        } catch {
            try? runs.finish(
                runId: runId, status: .failed, exitCode: exitCode,
                event: .failed, detail: "could not open a PR: \(error)"
            )
        }
        await hub?.broadcast()
    }

    private func openPullRequest(repo: RepoConfig, branch: String, issue: ReadyIssue) async throws -> URL {
        let directory = URL(filePath: repo.path, directoryHint: .isDirectory)
        let base = (try? cache.read(CacheStore.Key.repository(repo), as: RepositoryInfo.self))?
            .value.defaultBranch ?? "main"

        // A run that started an hour ago is opening against a base that has
        // moved. Rebase before the PR so the diff is honest.
        try await GitReader.run(["fetch", "origin", "--prune"], in: directory)
        try await GitReader.run(["rebase", "origin/\(base)", branch], in: directory)
        try await GitReader.run(["push", "-u", "origin", branch], in: directory)

        let pr = try await client.openPullRequest(
            owner: repo.owner, name: repo.name,
            title: "\(issue.title) (#\(issue.number))",
            head: branch, base: base,
            body: "Closes #\(issue.number)\n\nOpened by WorkflowHost. Review before merging — nothing here merges automatically."
        )
        return pr.url
    }

    private func moveCard(issue: ReadyIssue, in repo: RepoConfig, to column: String) async throws {
        guard let board = try? cache.read(CacheStore.Key.project(repo), as: ProjectSnapshot.self)?.value,
              let item = board.items.first(where: { $0.content?.number == issue.number })
        else { return }
        try await client.moveCard(item, to: column, in: board)
    }

    // MARK: - Stop

    /// Kills the session and marks the run failed, leaving the worktree in place
    /// for inspection. Cleanup is a separate, explicit act.
    public func stopRun(id: Int64) async throws {
        if let process = children[id], process.isRunning {
            process.terminate()
        } else if let run = try runs.run(id: id), let pid = run.pid {
            kill(pid, SIGTERM)
        }
        children[id] = nil
        try runs.finish(
            runId: id, status: .failed, exitCode: nil,
            event: .stopped, detail: "stopped from the dashboard"
        )
        await hub?.broadcast()
    }

    public var liveRunCount: Int { children.count }
}

public enum DispatchOutcome: Sendable, Equatable {
    case dispatched(repo: String, issue: Int, runId: Int64)
    case idle(repo: String, skipped: Int)
    case failed(repo: String, issue: Int, reason: String)
}

public enum DispatchError: Error, CustomStringConvertible {
    case disabled

    public var description: String {
        "the dispatcher is disabled — nothing was dispatched"
    }
}

/// Lets the dashboard's stop endpoint reach the dispatcher without the API layer
/// knowing anything else about it.
extension Dispatcher: DashboardServer.DashboardControls {}
