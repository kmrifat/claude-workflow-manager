//
//  TerminalSession.swift
//  workflow-manager
//
//  One terminal: a persistent interactive shell, and the screen it draws on.
//
//  A saved command is not a special kind of process — the session starts a
//  shell and *types* the command into it. That is why the prompt, history,
//  Ctrl-C and `cd` all behave normally afterwards, and why there is only one
//  code path to get wrong.
//
//  Output arrives on a background queue in 8KB chunks and has to reach SwiftUI.
//  It is buffered under a lock and folded into the emulator on a timer rather
//  than per chunk: a webpack rebuild emits hundreds of writes a second, and one
//  observable mutation each would spend the whole frame budget in diffing.
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case idle
        case running
        case exited(code: Int32)
        case failed(String)
    }

    nonisolated let id: UUID
    /// `nil` for an ad-hoc terminal with no saved command behind it.
    nonisolated let commandUUID: UUID?

    private(set) var title: String
    private(set) var command: String
    private(set) var directory: URL
    private(set) var state: State = .idle
    private(set) var startedAt: Date?

    /// The screen. Rebuilt incrementally as bytes arrive.
    private(set) var screen = TerminalEmulator(columns: 100, rows: 30)

    private var shell: InteractiveShell?
    /// Whether the last close was asked for.
    ///
    /// A shell told to go away exits non-zero — SIGHUP leaves 129, and `exit`
    /// from a job-control shell often leaves 1 — so reporting the raw code makes
    /// a perfectly normal close look like a crash.
    private var wasStoppedDeliberately = false
    private let incoming = ByteBuffer()
    private var drainTask: Task<Void, Never>?

    /// 20fps: smooth to read, and cheap.
    private static let drainInterval: Duration = .milliseconds(50)

    init(
        id: UUID = UUID(),
        commandUUID: UUID? = nil,
        title: String,
        command: String,
        directory: URL
    ) {
        self.id = id
        self.commandUUID = commandUUID
        self.title = title
        self.command = command
        self.directory = directory
    }

    var isRunning: Bool { state == .running }

    var statusSummary: String {
        switch state {
        case .idle:                "Not started"
        case .running:             "Shell running"
        case .exited(let code):    code == 0 ? "Closed" : "Closed (\(code))"
        case .failed(let message): message
        }
    }

    var plainTextOutput: String { screen.allText }

    // MARK: - Lifecycle

    /// Starts the shell if it is not already up.
    func startShell() {
        guard !isRunning else { return }

        screen = TerminalEmulator(
            columns: screen.columns,
            rows: screen.rows
        )
        state = .running
        startedAt = .now
        // Reset per run, or one deliberate close would mask every later crash.
        wasStoppedDeliberately = false

        let shell = InteractiveShell()
        self.shell = shell
        let buffer = incoming

        do {
            try shell.start(
                directory: directory,
                columns: screen.columns,
                rows: screen.rows,
                onOutput: { data in buffer.append(data) },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in self?.finish(code: code) }
                }
            )
        } catch {
            state = .failed(error.localizedDescription)
            self.shell = nil
            return
        }
        startDraining()
    }

    /// Starts the shell if needed, then types the saved command into it.
    ///
    /// The delay is for the shell's own startup: `.zshrc` and `oh-my-zsh` take
    /// a moment, and a command typed before `zle` is ready is swallowed.
    func runSavedCommand() {
        guard !command.isEmpty else { return }

        if !isRunning {
            startShell()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.isRunning else { return }
                self.send(self.command + TerminalKeys.enter)
            }
        } else {
            // Interrupt whatever is there so a restart does not type into a
            // running program.
            send(TerminalKeys.control("C") ?? "")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                self.send(self.command + TerminalKeys.enter)
            }
        }
    }

    /// Keystrokes, verbatim.
    func send(_ text: String) {
        shell?.send(text)
    }

    func interrupt() {
        send(TerminalKeys.control("C") ?? "")
    }

    func resize(columns: Int, rows: Int) {
        guard columns != screen.columns || rows != screen.rows else { return }
        screen.resize(columns: columns, rows: rows)
        shell?.resize(columns: columns, rows: rows)
    }

    /// Ends the shell and everything it started.
    func stop() {
        wasStoppedDeliberately = true
        shell?.terminate()
    }

    /// Re-reads the saved command, so an edit takes effect next time.
    func update(title: String, command: String, directory: URL) {
        self.title = title
        self.command = command
        // Changing a running shell's directory would be a lie — it has its own
        // idea of where it is. Only an unstarted session picks up the new one.
        if !isRunning { self.directory = directory }
    }

    func clearScreen() {
        // What Ctrl-L does, and it keeps the shell's own state consistent.
        if isRunning {
            send(TerminalKeys.control("L") ?? "")
        } else {
            screen = TerminalEmulator(columns: screen.columns, rows: screen.rows)
        }
    }

    // MARK: - Plumbing

    private func startDraining() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                guard let self else { return }
                self.drain()
                if !self.isRunning, self.incoming.isEmpty { return }
            }
        }
    }

    private func drain() {
        let data = incoming.take()
        guard !data.isEmpty else { return }
        screen.feed(data)
    }

    private func finish(code: Int32) {
        drain()
        // A shell we asked to close reports whatever signal killed it. That is
        // not information the user needs, and shown as an exit code it reads as
        // a failure.
        state = .exited(code: wasStoppedDeliberately ? 0 : code)
        shell = nil
        drainTask?.cancel()
        drainTask = nil
        Task { @MainActor [weak self] in self?.drain() }
    }
}

/// A lock-guarded byte queue. The pty reader fills it from a background queue;
/// the session empties it on the main actor.
private final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    /// A runaway process must not exhaust memory before the drain catches up.
    private let cap = 1 << 20

    var isEmpty: Bool { lock.withLock { storage.isEmpty } }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
            if storage.count > cap {
                storage.removeFirst(storage.count - cap)
            }
        }
    }

    func take() -> Data {
        lock.withLock {
            defer { storage = Data() }
            return storage
        }
    }
}
