//
//  CommandRunner.swift
//  workflow-manager
//
//  The one place the app spawns a subprocess. Arguments as an array (never a
//  shell string), stdout and stderr captured separately, a timeout, and a
//  non-zero exit raised as an error. Everything that shells out goes through it.
//
//  This is why the app is not sandboxed: a sandboxed process cannot launch an
//  arbitrary binary like `gh`. See CLAUDE.md.
//

import Foundation

/// `nonisolated` because this target defaults every type to `@MainActor`, and
/// blocking the main actor on a subprocess would freeze the UI.
nonisolated enum CommandRunner {
    struct Output: Sendable {
        let standardOutput: String
        let standardError: String
    }

    enum Failure: Error, LocalizedError {
        case executableNotFound(name: String, searched: [String])
        case launchFailed(command: String, reason: String)
        case timedOut(command: String, seconds: TimeInterval)
        case exited(command: String, code: Int32, standardError: String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let name, let searched):
                return "Could not find \(name). Looked in: \(searched.joined(separator: ", "))."
            case .launchFailed(let command, let reason):
                return "Could not run \(command): \(reason)"
            case .timedOut(let command, let seconds):
                return "\(command) did not finish within \(Int(seconds))s."
            case .exited(let command, let code, let standardError):
                let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "\(command) failed with exit code \(code)."
                    : detail
            }
        }
    }

    /// A GUI app launched from Finder inherits a minimal `PATH` — not the one
    /// from a login shell. Anything spawned here gets this instead, and
    /// executables are resolved by absolute path rather than by name.
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func locate(_ name: String) throws -> URL {
        try locate(name, in: searchPaths)
    }

    private static func locate(_ name: String, in directories: [String]) throws -> URL {
        for directory in directories {
            let candidate = URL(filePath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        throw Failure.executableNotFound(name: name, searched: directories)
    }

    /// `UserDefaults` key holding an absolute path the user picked by hand.
    static let claudeExecutableDefaultsKey = "ClaudeExecutablePath"

    /// `claude` ships through npm, nvm, bun, volta or the official installer —
    /// none of which land in the six directories `gh` and `git` live in, so
    /// `locate("claude")` genuinely fails on a normal machine. `searchPaths` is
    /// left alone rather than widened: broadening it would change how `gh` and
    /// `git` resolve, which is documented behaviour.
    ///
    /// Never resolved through a login shell (`zsh -lc which claude`) — that
    /// would mean building a shell string, which this type exists to avoid.
    static func locateClaude() throws -> URL {
        if let path = UserDefaults.standard.string(forKey: claudeExecutableDefaultsKey),
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return try locate("claude", in: claudeSearchPaths)
    }

    /// Where `claude` plausibly lives, most specific first. Version-stamped nvm
    /// directories are enumerated last and newest-first, because the path
    /// changes every time Node is upgraded and cannot be hardcoded.
    static var claudeSearchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appending(path: ".claude/local").path(percentEncoded: false),
            home.appending(path: ".local/bin").path(percentEncoded: false),
            home.appending(path: ".bun/bin").path(percentEncoded: false),
            home.appending(path: ".volta/bin").path(percentEncoded: false),
        ]
        paths.append(contentsOf: searchPaths)
        paths.append(contentsOf: nvmBinDirectories(under: home))
        return paths
    }

    private static func nvmBinDirectories(under home: URL) -> [String] {
        let versions = home.appending(path: ".nvm/versions/node")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        // Newest first, so an upgraded Node wins over a stale install.
        return contents
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map(\.lastPathComponent)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versions.appending(path: "\($0)/bin").path(percentEncoded: false) }
    }

    /// Spawns without waiting, returning the live child.
    ///
    /// For long-lived children — a `claude` remote-control session — where the
    /// pid is the point and the output is a log rather than a result.
    ///
    /// No pipes, so there is nothing to drain and nothing to deadlock: stdout
    /// and stderr both go to a descriptor the kernel owns. `run`'s concurrent
    /// drain exists only because a pipe's buffer is 64KB.
    ///
    /// Synchronous, so a `@MainActor` caller reaches it without an isolation
    /// hop — `Process` is not `Sendable` and must not cross one.
    @discardableResult
    static func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        standardOutput: URL? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":")
        process.environment = environment

        if let standardOutput {
            let path = standardOutput.path(percentEncoded: false)
            FileManager.default.createFile(atPath: path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: standardOutput) {
                process.standardOutput = handle
                process.standardError = handle
            }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(
                command: executable.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        return process
    }

    /// Runs `executable`, returning its output or throwing on failure.
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Output {
        let label = ([executable.lastPathComponent] + arguments).joined(separator: " ")

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":")
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(command: label, reason: error.localizedDescription)
        }

        let didTimeOut = LockedFlag()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
                didTimeOut.set()
                process.terminate()
            }
        }
        defer { watchdog.cancel() }

        let output = await Task.detached(priority: .userInitiated) {
            drain(process: process, standardOutput: standardOutput, standardError: standardError)
        }.value

        if didTimeOut.isSet {
            throw Failure.timedOut(command: label, seconds: timeout)
        }

        let result = Output(
            standardOutput: String(decoding: output.0, as: UTF8.self),
            standardError: String(decoding: output.1, as: UTF8.self)
        )

        guard process.terminationStatus == 0 else {
            throw Failure.exited(
                command: label,
                code: process.terminationStatus,
                standardError: result.standardError
            )
        }
        return result
    }

    /// Reads both pipes to EOF and waits for the child.
    ///
    /// Synchronous on purpose — it blocks, so it must only ever be called from a
    /// detached task, never from an async context directly.
    ///
    /// Both pipes have to be drained concurrently. Reading one to the end first
    /// can deadlock: the child blocks writing to the other once its 64KB buffer
    /// fills, and so never exits, and so the first read never sees EOF.
    private static func drain(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe
    ) -> (Data, Data) {
        let errorBuffer = LockedData()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errorBuffer.set((try? standardError.fileHandleForReading.readToEnd()) ?? Data())
            finished.signal()
        }

        let outputData = (try? standardOutput.fileHandleForReading.readToEnd()) ?? Data()
        finished.wait()
        process.waitUntilExit()
        return (outputData, errorBuffer.value)
    }
}

// MARK: - Small locked boxes
//
// The subprocess is driven from a detached task and a watchdog task at once, so
// the handful of values they share need real synchronisation.

private nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private nonisolated final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) { lock.withLock { storage = data } }
    var value: Data { lock.withLock { storage } }
}
