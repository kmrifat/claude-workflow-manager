//
//  ClaudeSessionModel.swift
//  workflow-manager
//
//  Owns the running `claude remote-control` process for one project.
//
//  In-memory only. The server outlives this app on purpose — quitting Workflow
//  Manager must not kill a session someone is driving from their phone — so a
//  relaunch shows "not running" even when a server is up. Adopting a pid across
//  launches would mean trusting a number the OS may have recycled.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeSessionModel {
    enum Phase {
        case idle
        case starting
        case running(ClaudeLauncher.Session)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The child. Never leaves the main actor — `Process` is not `Sendable`.
    private var process: Process?

    /// How long to wait before deciding the launch actually took.
    ///
    /// `remote-control` is an Ink terminal UI and we hand it `/dev/null` for
    /// stdin, which it may refuse. Reporting "running" for a process that
    /// already died would be worse than a short delay.
    private static let settleDelay: Duration = .milliseconds(1500)

    var session: ClaudeLauncher.Session? {
        if case .running(let session) = phase { return session }
        return nil
    }

    var isRunning: Bool { session != nil }

    var isStarting: Bool {
        if case .starting = phase { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func start(for project: Project) async {
        guard !isRunning, !isStarting else { return }
        guard let repository = project.repoDirectory else {
            phase = .failed("This project has no linked repository.")
            return
        }

        phase = .starting
        do {
            let started = try ClaudeLauncher.start(
                in: repository,
                namePrefix: project.name.isEmpty ? "workflow" : project.name
            )
            process = started.process

            try? await Task.sleep(for: Self.settleDelay)

            // Died on its own: report why rather than showing a session that
            // does not exist.
            if !started.process.isRunning {
                let failure = ClaudeLauncher.diagnose(
                    exitCode: started.process.terminationStatus,
                    log: ClaudeLauncher.logTail(at: started.session.logURL)
                )
                process = nil
                phase = .failed(message(for: failure))
                return
            }

            phase = .running(started.session)
            watch(started.process, session: started.session)
        } catch let failure as ClaudeLauncher.Failure {
            process = nil
            phase = .failed(message(for: failure))
        } catch {
            process = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// The reason plus its fix, which for these failures is usually a command
    /// the user has to run somewhere else.
    private func message(for failure: ClaudeLauncher.Failure) -> String {
        [failure.errorDescription, failure.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    /// Stops the server this app started. A server started elsewhere is not
    /// ours to kill.
    func stop() {
        process?.terminate()
        process = nil
        phase = .idle
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    /// `waitUntilExit` blocks, so it goes to a detached task and reports back.
    private func watch(_ process: Process, session: ClaudeLauncher.Session) {
        Task { [weak self] in
            let code = await Task.detached { () -> Int32 in
                process.waitUntilExit()
                return process.terminationStatus
            }.value

            guard let self else { return }
            // A newer session may have replaced this one while we waited.
            guard self.session == session else { return }

            self.process = nil
            self.phase = code == 0
                ? .idle
                : .failed("The Claude session exited with code \(code).")
        }
    }
}
