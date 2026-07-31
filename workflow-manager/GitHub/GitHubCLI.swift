//
//  GitHubCLI.swift
//  workflow-manager
//
//  Everything GitHub goes through the `gh` CLI, which already holds the user's
//  auth — the app never sees, stores, or asks for a token.
//
//  Read-only with exactly one exception: `createIssue`, which files a new issue
//  from a board card. It is the only function in this app that changes anything
//  on GitHub, it is never called without the user confirming the exact title and
//  body first, and it still cannot edit, close, assign or comment on anything
//  that already exists. Keep it that way — the rule this repo relies on is that
//  GitHub state flows *into* the app, never the reverse.
//

import Foundation

/// `nonisolated` so fetching and JSON decoding stay off the main actor — this
/// target isolates every type to `@MainActor` unless told otherwise.
nonisolated enum GitHubCLI {
    enum Failure: Error, LocalizedError {
        case notInstalled
        case notAuthenticated
        case notAGitRepository(URL)
        case noGitHubRemote
        case commandFailed(String)
        case malformedOutput(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The GitHub CLI (gh) isn’t installed. Install it with `brew install gh`."
            case .notAuthenticated:
                return "The GitHub CLI isn’t signed in. Run `gh auth login` in Terminal."
            case .notAGitRepository(let url):
                return "\(url.lastPathComponent) isn’t a Git repository — no .git directory inside it."
            case .noGitHubRemote:
                return "This repository has no GitHub remote, so there are no issues to show."
            case .commandFailed(let message):
                return message
            case .malformedOutput(let detail):
                return "Couldn’t read the response from gh: \(detail)"
            }
        }
    }

    /// A directory is usable only if it actually contains a `.git`.
    static func validateGitDirectory(_ directory: URL) throws {
        let git = directory.appending(path: ".git")
        guard FileManager.default.fileExists(atPath: git.path(percentEncoded: false)) else {
            throw Failure.notAGitRepository(directory)
        }
    }

    static func repository(at directory: URL) async throws -> GitHubRepository {
        try validateGitDirectory(directory)
        let output = try await run(
            ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"],
            in: directory
        )
        return try decode(GitHubRepository.self, from: output)
    }

    /// Open issues, most recently updated first.
    ///
    /// `gh issue list` excludes pull requests already, unlike the REST endpoint.
    static func openIssues(at directory: URL, limit: Int = 100) async throws -> [GitHubIssue] {
        try validateGitDirectory(directory)
        let output = try await run(
            [
                "issue", "list",
                "--state", "open",
                "--limit", String(limit),
                // Scalars only. `comments` is available here too, but it inlines
                // every comment body for every issue, which makes the list
                // request enormous — the detail view links out instead.
                "--json", "number,title,state,url,body,labels,assignees,author,milestone,createdAt,updatedAt",
            ],
            in: directory
        )
        return try decode([GitHubIssue].self, from: output)
    }

    // MARK: - The one write

    /// A freshly filed issue, as much as `gh` tells us about it.
    struct CreatedIssue: Sendable, Equatable {
        let number: Int
        let url: URL
    }

    /// Files a new issue and returns its number, so the calling card can link
    /// itself to it.
    ///
    /// `--title` and `--body` are always passed, even when the body is empty:
    /// omitting either makes `gh` prompt interactively, and stdin is
    /// `/dev/null`, so it would fail with a confusing error instead of an
    /// obvious one.
    ///
    /// `gh` prints the new issue's URL on stdout and nothing else. The number is
    /// the last path component — there is no `--json` for this subcommand.
    static func createIssue(
        at directory: URL,
        title: String,
        body: String,
        labels: [String] = []
    ) async throws -> CreatedIssue {
        try validateGitDirectory(directory)

        var arguments = ["issue", "create", "--title", title, "--body", body]
        for label in labels {
            arguments.append(contentsOf: ["--label", label])
        }

        let output = try await run(arguments, in: directory)
        let line = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("http") }

        guard let line,
              let url = URL(string: line),
              let number = Int(url.lastPathComponent)
        else {
            throw Failure.malformedOutput(
                "expected an issue URL from gh, got \"\(output.trimmingCharacters(in: .whitespacesAndNewlines))\""
            )
        }
        return CreatedIssue(number: number, url: url)
    }

    // MARK: - Plumbing

    private static func run(_ arguments: [String], in directory: URL) async throws -> String {
        let executable: URL
        do {
            executable = try CommandRunner.locate("gh")
        } catch {
            throw Failure.notInstalled
        }

        do {
            let output = try await CommandRunner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory
            )
            return output.standardOutput
        } catch let failure as CommandRunner.Failure {
            throw translate(failure)
        }
    }

    /// `gh` reports everything as a non-zero exit with prose on stderr. These
    /// are the cases worth telling apart, because each has a different fix.
    private static func translate(_ failure: CommandRunner.Failure) -> Failure {
        guard case .exited(_, _, let standardError) = failure else {
            return .commandFailed(failure.localizedDescription)
        }
        let message = standardError.lowercased()

        if message.contains("gh auth login") || message.contains("authentication token") {
            return .notAuthenticated
        }
        if message.contains("none of the git remotes") || message.contains("no git remotes found") {
            return .noGitHubRemote
        }
        return .commandFailed(
            standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw Failure.malformedOutput(String(describing: error))
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
