import Foundation

/// The one place the host spawns a subprocess.
///
/// Arguments as an array (never a shell string), stdout and stderr drained
/// concurrently, a timeout, and non-zero exit raised as an error. `git`,
/// `claude` and `cloudflared` all go through it.
///
/// This is why the host is not sandboxed.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let standardOutput: String
        public let standardError: String
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case executableNotFound(name: String, searched: [String])
        case launchFailed(command: String, reason: String)
        case timedOut(command: String, seconds: TimeInterval)
        case exited(command: String, code: Int32, standardError: String)

        public var description: String {
            switch self {
            case .executableNotFound(let name, let searched):
                return "could not find \(name) — looked in \(searched.joined(separator: ", "))"
            case .launchFailed(let command, let reason):
                return "could not run \(command): \(reason)"
            case .timedOut(let command, let seconds):
                return "\(command) did not finish within \(Int(seconds))s"
            case .exited(let command, let code, let standardError):
                let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "\(command) exited \(code)"
                    : "\(command) exited \(code): \(detail)"
            }
        }
    }

    /// Executables are resolved by absolute path. When the host is launched by
    /// launchd or embedded in an app bundle it inherits a minimal `PATH`, not a
    /// login shell's.
    public static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    public static func locate(_ name: String) throws -> URL {
        for directory in searchPaths {
            let candidate = URL(filePath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        throw Failure.executableNotFound(name: name, searched: searchPaths)
    }

    @discardableResult
    public static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 60
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

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(command: label, reason: error.localizedDescription)
        }

        let timedOut = LockedBox(false)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        defer { watchdog.cancel() }

        let (outData, errData) = await Task.detached(priority: .userInitiated) {
            drain(process: process, standardOutput: outPipe, standardError: errPipe)
        }.value

        if timedOut.value {
            throw Failure.timedOut(command: label, seconds: timeout)
        }

        let output = Output(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
        guard process.terminationStatus == 0 else {
            throw Failure.exited(
                command: label,
                code: process.terminationStatus,
                standardError: output.standardError
            )
        }
        return output
    }

    /// Spawns without waiting. Used for long-lived children — a `claude` session
    /// or a `cloudflared` tunnel — where the pid is the point.
    public static func spawn(
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
            FileManager.default.createFile(atPath: standardOutput.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: standardOutput)
            process.standardOutput = handle
            process.standardError = handle
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

    /// Blocking; only ever called from a detached task.
    ///
    /// Both pipes are drained concurrently — reading one to EOF first deadlocks
    /// once the child fills the other's 64KB buffer.
    private static func drain(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe
    ) -> (Data, Data) {
        let errorBuffer = LockedBox(Data())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errorBuffer.value = (try? standardError.fileHandleForReading.readToEnd()) ?? Data()
            finished.signal()
        }
        let outputData = (try? standardOutput.fileHandleForReading.readToEnd()) ?? Data()
        finished.wait()
        process.waitUntilExit()
        return (outputData, errorBuffer.value)
    }
}

/// Shared between the watchdog task and the draining task.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
