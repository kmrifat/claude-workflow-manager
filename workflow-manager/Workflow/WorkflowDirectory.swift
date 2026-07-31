//
//  WorkflowDirectory.swift
//  workflow-manager
//
//  `.taskboard/` inside a linked repository: the shared surface between this app
//  and a Claude Code session running in that repo.
//
//  The name is deliberately *not* `.workflow` — that collides with how everyone
//  reads "workflow" (GitHub Actions, CI). `.taskboard` says what the directory
//  is: the board's task mirror and the contract that goes with it. It is the one
//  place the on-disk name is defined; the contract text below derives from it.
//
//  It lives in the repo because a session started there has to find it by
//  convention — `claude remote-control` takes no prompt, so there is no way to
//  hand it a path. It is ignored by git because GitHub issues are the team's
//  layer and this is local AI-work state; committing it would also mean merge
//  conflicts on a file two programs rewrite.
//

import Foundation

nonisolated enum WorkflowDirectory {
    static let name = ".taskboard"

    /// Repository-relative paths, so every mention in the UI and the agent
    /// contract stays in step with `name` instead of hardcoding it.
    static var tasksPath: String { "\(name)/tasks.json" }
    static var readmePath: String { "\(name)/README.md" }

    static func url(in repository: URL) -> URL {
        repository.appending(path: name, directoryHint: .isDirectory)
    }

    static func tasksURL(in repository: URL) -> URL {
        url(in: repository).appending(path: "tasks.json")
    }

    static func sessionLogURL(in repository: URL) -> URL {
        url(in: repository).appending(path: "session.log")
    }

    static func sessionInfoURL(in repository: URL) -> URL {
        url(in: repository).appending(path: "session.json")
    }

    static func readmeURL(in repository: URL) -> URL {
        url(in: repository).appending(path: "README.md")
    }

    /// Creates the directory and its self-ignoring `.gitignore`.
    ///
    /// The `.gitignore` holds a single `*`, which ignores the directory's whole
    /// contents *including itself*. That keeps the repository's own committed
    /// `.gitignore` untouched — an app must not silently edit a file the user
    /// has checked in.
    static func ensure(in repository: URL) throws {
        let directory = url(in: repository)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let gitignore = directory.appending(path: ".gitignore")
        guard !FileManager.default.fileExists(atPath: gitignore.path(percentEncoded: false)) else {
            return
        }
        try Data("*\n".utf8).write(to: gitignore, options: .atomic)
    }

    // MARK: - The agent contract
    //
    // `claude remote-control` accepts no prompt, so everything the agent needs
    // to know has to be readable from the repository. Both documents below are
    // shown to the user in full and written only on confirmation.

    // These two are identifiers, not prose: they are already sitting in other
    // people's `CLAUDE.md` files, and `applyingMemorySnippet(to:)` finds the
    // previous block by matching them. Renaming them to match the product's
    // "Claude WM" name would make every existing block invisible and get a
    // second one appended below it.
    static let claudeMemoryBeginMarker = "<!-- workflow-manager:begin -->"
    static let claudeMemoryEndMarker = "<!-- workflow-manager:end -->"

    /// The contract itself, written to `\(name)/README.md`.
    static func readme(projectName: String, repositorySlug: String?) -> String {
        """
        # Workflow tasks

        `tasks.json` in this directory mirrors the **\(projectName)** board in
        Claude WM\(repositorySlug.map { " for `\($0)`" } ?? ""). The app watches this file; edits
        you make here show up on the board within a second.

        ## Picking up work

        Rows with `"requested": true` are work the user has explicitly sent to
        you. Start with those, oldest `updatedAt` first.

        ## Reporting progress

        When you **begin** a task, set on that row:

        - `"status": "in_progress"`
        - `"source": "claude"`
        - `"updatedAt"`: the current time, ISO-8601 with a `Z` suffix

        When you **open a pull request**, set on that row:

        - `"status": "review"`
        - `"branch"`: the branch name
        - `"prUrl"`: the pull request URL
        - `"source": "claude"` and a fresh `"updatedAt"`

        Also set the envelope's `"writer"` to `"claude"` and refresh its
        `"updatedAt"` on every write. Leave `"version"` at `1`.

        ## The status vocabulary

        Exactly these four values, and no others:

        | Status | Meaning |
        |---|---|
        | `todo` | not started |
        | `in_progress` | being worked on now |
        | `review` | a pull request is open |
        | `done` | merged or otherwise finished |

        A row with any other status is ignored by the app.

        ## Fields you own, and fields you don't

        You own `status`, `branch` and `prUrl` — you are the only party that
        observes them.

        **Do not edit** `title`, `details`, `githubIssue` or `requested`. The app
        owns those and will overwrite whatever you put there.

        ## Adding work

        Append a row with a fresh UUID `id`, `"source": "claude"` and a status of
        `todo`. It appears on the board as a new card.

        ## Writing the file

        Rewrite it whole and atomically — write a temporary file, then rename it
        over `tasks.json`. A partially written file is read as corrupt, and the
        app will keep showing the last good state rather than clear the board.
        """
    }

    /// A pointer for the repository's own `CLAUDE.md`, so a session loads the
    /// contract without the user typing anything. Wrapped in markers so
    /// rewriting it is idempotent.
    static func claudeMemorySnippet() -> String {
        """
        \(claudeMemoryBeginMarker)
        ## Claude WM

        This repository is tracked on a Claude WM board. `\(tasksPath)`
        is the shared task list: rows with `"requested": true` are work assigned to
        you, and you report progress by setting a row's `status` to `in_progress`
        when you start and `review` when you open a PR.

        Read `\(readmePath)` for the full contract before touching that file.
        \(claudeMemoryEndMarker)
        """
    }

    /// Splices the snippet into an existing `CLAUDE.md` body, replacing a
    /// previous block rather than appending a second one.
    static func applyingMemorySnippet(to existing: String) -> String {
        let snippet = claudeMemorySnippet()
        guard let start = existing.range(of: claudeMemoryBeginMarker),
              let end = existing.range(of: claudeMemoryEndMarker)
        else {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? snippet + "\n" : trimmed + "\n\n" + snippet + "\n"
        }
        var updated = existing
        updated.replaceSubrange(start.lowerBound..<end.upperBound, with: snippet)
        return updated
    }
}
