//
//  ClaudeLauncher.swift
//  workflow-manager
//
//  Starts a Claude Code Remote Control server in a linked repository, so
//  sessions for that repo can be opened from claude.ai/code or the Claude
//  mobile app.
//
//  Shaped like `GitHubCLI`: a `nonisolated enum`, one job, its own
//  `LocalizedError`. Spawning still goes through `CommandRunner`, which remains
//  the only place this app starts a subprocess.
//
//  Nothing here talks to GitHub, and nothing here proxies the session's output.
//  The log file exists to diagnose a launch that failed; reading the
//  conversation is the Claude app's job.
//

import Foundation

nonisolated enum ClaudeLauncher {
    enum Failure: Error, LocalizedError {
        case notInstalled(searched: [String])
        case notARepository(URL)
        case notSignedIn
        case launchFailed(String)
        case exitedImmediately(code: Int32, log: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Could not find the `claude` command. Install Claude Code, or point at it from the repository menu."
            case .notARepository(let url):
                return "\(url.lastPathComponent) isn’t a Git repository — no .git directory inside it."
            case .notSignedIn:
                return "Remote Control needs a claude.ai subscription and a signed-in Claude Code."
            case .launchFailed(let reason):
                return reason
            case .exitedImmediately(let code, let log):
                let detail = log.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "The Claude session exited immediately (code \(code))."
                    : "The Claude session exited immediately (code \(code)): \(detail)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notInstalled(let searched):
                return "Looked in: \(searched.joined(separator: ", "))."
            case .notSignedIn:
                return "Run `claude` in Terminal and use `/login` to sign in with your claude.ai account."
            case .exitedImmediately:
                return "Run `claude remote-control` in this repository from Terminal to see what it reports."
            default:
                return nil
            }
        }
    }

    /// Turns an immediate exit into the specific reason where we recognise one.
    ///
    /// Not being signed in is by far the most common way this fails, and the
    /// fix is a command the user runs elsewhere — worth saying plainly instead
    /// of quoting a log.
    static func diagnose(exitCode: Int32, log: String) -> Failure {
        let text = log.lowercased()
        if text.contains("must be logged in") || text.contains("/login") {
            return .notSignedIn
        }
        return .exitedImmediately(code: exitCode, log: log)
    }

    /// A running Remote Control server.
    struct Session: Sendable, Equatable {
        let pid: Int32
        let namePrefix: String
        let startedAt: Date
        let repository: URL
        let logURL: URL
    }

    static var isInstalled: Bool {
        (try? CommandRunner.locateClaude()) != nil
    }

    /// Starts a Remote Control server whose working directory is `repository`.
    ///
    /// `--spawn same-dir` (the default) on purpose. `worktree` — which
    /// WorkflowHost uses, because it creates the worktree itself — would give
    /// every on-demand session its own checkout, and therefore its own
    /// `.taskboard/tasks.json`. That is a different file from the one this app
    /// watches, so the board would never see the agent's progress.
    static func start(
        in repository: URL,
        namePrefix: String
    ) throws -> (process: Process, session: Session) {
        do {
            try GitHubCLI.validateGitDirectory(repository)
        } catch {
            throw Failure.notARepository(repository)
        }

        let executable: URL
        do {
            executable = try CommandRunner.locateClaude()
        } catch {
            throw Failure.notInstalled(searched: CommandRunner.claudeSearchPaths)
        }

        try? WorkflowDirectory.ensure(in: repository)
        let logURL = WorkflowDirectory.sessionLogURL(in: repository)

        let process: Process
        do {
            process = try CommandRunner.spawn(
                executable: executable,
                arguments: [
                    "remote-control",
                    "--spawn", "same-dir",
                    "--remote-control-session-name-prefix", namePrefix,
                ],
                workingDirectory: repository,
                standardOutput: logURL
            )
        } catch let failure as CommandRunner.Failure {
            throw Failure.launchFailed(failure.localizedDescription)
        }

        let session = Session(
            pid: process.processIdentifier,
            namePrefix: namePrefix,
            startedAt: .now,
            repository: repository,
            logURL: logURL
        )
        writeSessionInfo(session)
        return (process, session)
    }

    /// The tail of the session log, for reporting a launch that died on its own.
    static func logTail(at url: URL, limit: Int = 600) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count <= limit ? text : String(text.suffix(limit))
    }

    /// A breadcrumb for the human, not state this app reads back.
    ///
    /// The server deliberately outlives the app — quitting Claude WM
    /// should not kill a session someone is talking to from their phone — but
    /// adopting a pid across launches would mean trusting a number that may
    /// have been recycled. So: written, never re-read.
    private static func writeSessionInfo(_ session: Session) {
        let info: [String: Any] = [
            "pid": Int(session.pid),
            "namePrefix": session.namePrefix,
            "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: info,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: WorkflowDirectory.sessionInfoURL(in: session.repository),
            options: .atomic
        )
    }
}
