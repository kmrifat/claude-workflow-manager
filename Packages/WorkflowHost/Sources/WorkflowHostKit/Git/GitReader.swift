import Foundation
import WorkflowCore

/// Read-only git for the host.
///
/// Summaries are cached under `gitsum:<repo>:<branch>` with a 30s TTL, so the
/// dashboard polling every few seconds does not shell out every time.
public struct GitReader: Sendable {
    private let cache: CacheStore

    /// Matches the build plan's TTL.
    public static let cacheLifetime: TimeInterval = 30

    public init(cache: CacheStore) {
        self.cache = cache
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAGitRepository(String)
        case branchMissing(String)
        case gitFailed(String)

        public var description: String {
            switch self {
            case .notAGitRepository(let path): "\(path) is not a git repository"
            case .branchMissing(let branch): "no branch named \(branch)"
            case .gitFailed(let message): message
            }
        }
    }

    public static func cacheKey(repo: String, branch: String) -> String {
        "gitsum:\(repo):\(branch)"
    }

    /// Cached summary, refreshed when older than the TTL.
    public func summary(
        repo: RepoConfig,
        branch: String,
        base: String,
        now: Date = Date()
    ) async throws -> GitSummary {
        let key = Self.cacheKey(repo: repo.id, branch: branch)

        if let cached = try? cache.read(key, as: GitSummary.self),
           now.timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.value
        }

        let summary = try await Self.readSummary(
            at: URL(filePath: repo.path, directoryHint: .isDirectory),
            branch: branch,
            base: base
        )
        try? cache.write(key, value: summary, etag: nil, at: now)
        return summary
    }

    // MARK: - Uncached primitives

    public static func readSummary(
        at directory: URL,
        branch: String,
        base: String
    ) async throws -> GitSummary {
        guard try await revisionExists(branch, in: directory) else {
            throw Failure.branchMissing(branch)
        }
        // A fresh clone often has only origin/<base> locally; comparing against
        // a ref that isn't there would fail rather than degrade.
        let resolvedBase = try await resolveBase(base, in: directory)
        let range = "\(resolvedBase)..\(branch)"

        async let commitsTask = commits(in: directory, range: range)
        async let statTask = diffStat(in: directory, range: range)
        let (commits, stat) = try await (commitsTask, statTask)

        return GitSummary(
            branch: branch,
            baseBranch: resolvedBase,
            commits: commits,
            filesChanged: stat.files,
            insertions: stat.insertions,
            deletions: stat.deletions
        )
    }

    public static func localBranches(at directory: URL) async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: directory)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func currentBranch(at directory: URL) async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commits(in directory: URL, range: String) async throws -> [GitSummary.Commit] {
        // Unit separator: commit subjects contain everything else.
        let output = try await run(["log", "--format=%h%x1f%ct%x1f%s", range], in: directory)
        return output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 3, let seconds = TimeInterval(fields[1]) else { return nil }
            return GitSummary.Commit(
                sha: fields[0],
                subject: fields[2],
                date: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    private static func diffStat(
        in directory: URL,
        range: String
    ) async throws -> (files: Int, insertions: Int, deletions: Int) {
        parseShortStat(try await run(["diff", "--shortstat", range], in: directory))
    }

    /// Parses ` 3 files changed, 10 insertions(+), 2 deletions(-)`. Any clause
    /// may be absent — a pure addition has no deletions clause at all.
    public static func parseShortStat(
        _ output: String
    ) -> (files: Int, insertions: Int, deletions: Int) {
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

    static func revisionExists(_ revision: String, in directory: URL) async throws -> Bool {
        do {
            _ = try await run(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], in: directory)
            return true
        } catch Failure.gitFailed {
            // `--quiet` exits non-zero with no output for a missing ref, which
            // is an answer rather than an error.
            return false
        }
    }

    static func resolveBase(_ base: String, in directory: URL) async throws -> String {
        if try await revisionExists(base, in: directory) { return base }
        if try await revisionExists("origin/\(base)", in: directory) { return "origin/\(base)" }
        return base
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) async throws -> String {
        let git: URL
        do { git = try ProcessRunner.locate("git") }
        catch { throw Failure.gitFailed("could not find git") }

        do {
            return try await ProcessRunner.run(
                executable: git, arguments: arguments,
                workingDirectory: directory, timeout: 30
            ).standardOutput
        } catch let failure as ProcessRunner.Failure {
            if case .exited(_, _, let stderr) = failure,
               stderr.lowercased().contains("not a git repository") {
                throw Failure.notAGitRepository(directory.path(percentEncoded: false))
            }
            throw Failure.gitFailed(failure.description)
        }
    }
}
