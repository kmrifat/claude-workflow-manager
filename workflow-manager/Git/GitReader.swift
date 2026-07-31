//
//  GitReader.swift
//  workflow-manager
//
//  Read-only git. Given a repository and a branch, answers how much work is on
//  it: commits, files touched, lines added and removed, and when it last moved.
//
//  Everything shells out through `CommandRunner`. Nothing here writes — no
//  checkout, no fetch, no commit.
//

import Foundation

nonisolated enum GitReader {
    struct Commit: Sendable, Equatable, Identifiable {
        let sha: String
        let subject: String
        let date: Date

        var id: String { sha }
    }

    struct BranchSummary: Sendable, Equatable {
        let branch: String
        /// What the branch was compared against — never assumed to be `main`.
        let baseBranch: String
        /// Newest first.
        let commits: [Commit]
        let filesChanged: Int
        let insertions: Int
        let deletions: Int

        var lastCommitAt: Date? { commits.first?.date }

        /// A branch that exists but has nothing on it yet. Real: a worktree is
        /// created before the first commit lands.
        var isEmpty: Bool { commits.isEmpty }

        var commitCount: Int { commits.count }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case notAGitRepository(String)
        case branchMissing(String)
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAGitRepository(let path):
                return "\(path) isn’t a Git repository."
            case .branchMissing(let branch):
                return "No local branch named \(branch)."
            case .gitFailed(let message):
                return message
            }
        }
    }

    // MARK: - Queries

    static func currentBranch(at directory: URL) async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local branch names.
    static func localBranches(at directory: URL) async throws -> [String] {
        let output = try await run(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: directory
        )
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether the working tree has uncommitted changes.
    static func hasUncommittedChanges(at directory: URL) async throws -> Bool {
        let output = try await run(["status", "--porcelain"], in: directory)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What is on `branch` that isn't on `base`.
    ///
    /// `base` comes from the repository's default branch as GitHub reports it —
    /// assuming `main` is wrong often enough to matter (`cli/cli` uses `trunk`).
    static func summary(
        at directory: URL,
        branch: String,
        base: String
    ) async throws -> BranchSummary {
        guard try await revisionExists(branch, in: directory) else {
            throw Failure.branchMissing(branch)
        }

        // A freshly cloned repo often has no local base branch, only
        // origin/<base>. Comparing against a ref that doesn't exist would fail
        // the whole summary rather than degrade.
        let resolvedBase = try await resolveBase(base, in: directory)
        let range = "\(resolvedBase)..\(branch)"

        async let commitsTask = commits(in: directory, range: range)
        async let statTask = diffStat(in: directory, range: range)
        let (commits, stat) = try await (commitsTask, statTask)

        return BranchSummary(
            branch: branch,
            baseBranch: resolvedBase,
            commits: commits,
            filesChanged: stat.files,
            insertions: stat.insertions,
            deletions: stat.deletions
        )
    }

    // MARK: - Pieces

    private static func commits(in directory: URL, range: String) async throws -> [Commit] {
        // Unit separator between fields: commit subjects contain everything
        // else, including tabs and pipes.
        let output = try await run(
            ["log", "--format=%h%x1f%ct%x1f%s", range],
            in: directory
        )

        return output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 3, let timestamp = TimeInterval(fields[1]) else { return nil }
            return Commit(
                sha: fields[0],
                subject: fields[2],
                date: Date(timeIntervalSince1970: timestamp)
            )
        }
    }

    private static func diffStat(
        in directory: URL,
        range: String
    ) async throws -> (files: Int, insertions: Int, deletions: Int) {
        let output = try await run(["diff", "--shortstat", range], in: directory)
        return parseShortStat(output)
    }

    /// Parses ` 3 files changed, 10 insertions(+), 2 deletions(-)`.
    ///
    /// Any of the three clauses can be absent — a commit that only adds files
    /// has no deletions clause at all, and an empty range prints nothing.
    static func parseShortStat(_ output: String) -> (files: Int, insertions: Int, deletions: Int) {
        var files = 0, insertions = 0, deletions = 0

        for clause in output.components(separatedBy: ",") {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed.prefix { $0.isNumber }) else { continue }
            if trimmed.contains("file") { files = value }
            else if trimmed.contains("insertion") { insertions = value }
            else if trimmed.contains("deletion") { deletions = value }
        }
        return (files, insertions, deletions)
    }

    private static func revisionExists(_ revision: String, in directory: URL) async throws -> Bool {
        do {
            _ = try await run(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], in: directory)
            return true
        } catch Failure.gitFailed {
            // `--quiet` makes a missing ref exit non-zero with no output, which
            // is the answer rather than an error.
            return false
        }
    }

    private static func resolveBase(_ base: String, in directory: URL) async throws -> String {
        if try await revisionExists(base, in: directory) { return base }
        if try await revisionExists("origin/\(base)", in: directory) { return "origin/\(base)" }
        return base
    }

    private static func run(_ arguments: [String], in directory: URL) async throws -> String {
        let git: URL
        do {
            git = try CommandRunner.locate("git")
        } catch {
            throw Failure.gitFailed("Could not find git.")
        }

        do {
            return try await CommandRunner.run(
                executable: git,
                arguments: arguments,
                workingDirectory: directory,
                timeout: 20
            ).standardOutput
        } catch let failure as CommandRunner.Failure {
            if case .exited(_, _, let stderr) = failure,
               stderr.lowercased().contains("not a git repository") {
                throw Failure.notAGitRepository(directory.path(percentEncoded: false))
            }
            throw Failure.gitFailed(failure.localizedDescription)
        }
    }
}
