//
//  TerminalSessionsModel.swift
//  workflow-manager
//
//  Every session for one project: one per saved command, plus any ad-hoc
//  terminals opened by hand.
//
//  Sessions outlive the view. Switching tabs or projects and back must not kill
//  a dev server, so this is held by an app-level `TerminalStateStore` (keyed by
//  project) rather than the terminal view or the detail view, and only
//  `stopAll()` ends anything.
//

import Foundation
import Observation

/// One sessions model per project, kept alive above the detail view so a running
/// dev server survives switching to another project and back. Without this the
/// model would die with `ProjectDetailView` (which is recreated per project),
/// orphaning its processes — the ports stay bound while the UI, rebuilt from a
/// fresh model, claims nothing is running. In memory only, for the app's run.
@MainActor
@Observable
final class TerminalStateStore {
    // Not observed: models are looked up during `body`, and each model is
    // observed on its own. Publishing dictionary inserts would mean mutating
    // observed state mid-render.
    @ObservationIgnored private var models: [UUID: TerminalSessionsModel] = [:]

    func model(for projectID: UUID) -> TerminalSessionsModel {
        if let existing = models[projectID] { return existing }
        let created = TerminalSessionsModel()
        models[projectID] = created
        return created
    }
}

@MainActor
@Observable
final class TerminalSessionsModel {
    private(set) var sessions: [TerminalSession] = []
    private(set) var projectUUID: UUID?
    /// Set while `runAll` is walking the list.
    private(set) var isStartingAll = false

    /// Gap between starts in "Run All".
    ///
    /// Commands in one project are usually related — a server, then a worker
    /// that talks to it. Starting them in the same instant is the one ordering
    /// that reliably loses that race, and a short stagger costs nothing.
    private static let staggerDelay: Duration = .milliseconds(400)

    var runningCount: Int { sessions.count(where: \.isRunning) }
    var hasRunning: Bool { runningCount > 0 }

    /// The session most recently started programmatically — a card launching a
    /// Claude session. `TerminalView` watches it to select the new session so it
    /// is in front the moment the user lands on the tab.
    private(set) var lastStartedID: UUID?

    // MARK: - Syncing with the saved commands

    /// Creates a session for each saved command, updates ones that changed, and
    /// drops those whose command was deleted.
    ///
    /// A running session is never dropped out from under its process — it is
    /// stopped first, so nothing is orphaned.
    func sync(with project: Project) {
        if projectUUID != project.uuid {
            stopAll()
            sessions = []
            projectUUID = project.uuid
        }

        let commands = project.orderedTerminalCommands
        let liveIDs = Set(commands.map(\.uuid))

        for session in sessions where session.commandUUID != nil {
            if !liveIDs.contains(session.commandUUID!) {
                session.stop()
            }
        }
        sessions.removeAll { session in
            guard let uuid = session.commandUUID else { return false }  // keep ad-hoc
            return !liveIDs.contains(uuid)
        }

        for command in commands {
            guard let directory = command.resolvedDirectory(in: project) else { continue }
            if let existing = sessions.first(where: { $0.commandUUID == command.uuid }) {
                existing.update(
                    title: command.displayName,
                    command: command.command,
                    directory: directory
                )
            } else {
                sessions.append(
                    TerminalSession(
                        commandUUID: command.uuid,
                        title: command.displayName,
                        command: command.command,
                        directory: directory
                    )
                )
            }
        }

        // Saved commands first, in board order; ad-hoc terminals after.
        let order = Dictionary(uniqueKeysWithValues: commands.enumerated().map { ($1.uuid, $0) })
        sessions.sort { lhs, rhs in
            switch (lhs.commandUUID, rhs.commandUUID) {
            case let (l?, r?): (order[l] ?? 0) < (order[r] ?? 0)
            case (_?, nil):    true
            case (nil, _?):    false
            default:           false
            }
        }
    }

    // MARK: - Running

    /// Starts every command marked for Run All, one after another.
    func runAll(for project: Project) {
        guard !isStartingAll else { return }
        let included = Set(
            project.orderedTerminalCommands
                .filter(\.isIncludedInRunAll)
                .map(\.uuid)
        )
        let targets = sessions.filter { session in
            guard let uuid = session.commandUUID else { return false }
            return included.contains(uuid) && !session.isRunning
        }
        guard !targets.isEmpty else { return }

        isStartingAll = true
        Task { [weak self] in
            defer { self?.isStartingAll = false }
            for (index, session) in targets.enumerated() {
                session.runSavedCommand()
                if index < targets.count - 1 {
                    try? await Task.sleep(for: Self.staggerDelay)
                }
            }
        }
    }

    func stopAll() {
        for session in sessions where session.isRunning {
            session.stop()
        }
    }

    // MARK: - Ad-hoc terminals

    @discardableResult
    func addAdHocSession(in directory: URL, named name: String? = nil) -> TerminalSession {
        let existing = sessions.count { $0.commandUUID == nil }
        let session = TerminalSession(
            title: name ?? "Terminal \(existing + 1)",
            command: "",
            directory: directory
        )
        sessions.append(session)
        return session
    }

    func remove(_ session: TerminalSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: - Claude sessions

    /// Opens an ad-hoc terminal running `claude` seeded with `prompt`, in
    /// `directory`. Ad-hoc (no `commandUUID`), so `sync(with:)` never sweeps it.
    ///
    /// `claude` is started the same way a saved command is — typed into a real
    /// shell — so Ctrl-C, scrollback and the interactive TUI all work normally.
    @discardableResult
    func startClaudeSession(title: String, prompt: String, in directory: URL) -> TerminalSession {
        let session = TerminalSession(
            title: title,
            command: "claude " + Self.singleQuoted(prompt),
            directory: directory
        )
        sessions.append(session)
        lastStartedID = session.id
        session.runSavedCommand()
        return session
    }

    /// Wraps arbitrary text in POSIX single quotes so the shell passes it to
    /// `claude` as one argument, newlines and all. The only character that has
    /// to be escaped inside single quotes is the single quote itself.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
