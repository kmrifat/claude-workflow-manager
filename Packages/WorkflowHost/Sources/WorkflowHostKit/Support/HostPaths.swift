import Foundation

/// Where the host keeps its state on disk.
///
/// This is the **only** file allowed to mention `applicationSupportDirectory` or
/// `~/Library`. Everything else takes a `HostPaths` and asks it for a URL, which
/// is what makes the whole daemon testable against a scratch directory.
public struct HostPaths: Sendable, Equatable {
    /// Environment variable that relocates the entire home directory. Used by
    /// tests, and by anyone running a second instance against a scratch database
    /// while the real one is live.
    public static let homeEnvironmentKey = "WORKFLOWHOST_HOME"

    /// The directory holding `config.json` and `db.sqlite`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `root` for display: a directory URL's path carries a trailing slash,
    /// which reads as a typo in the boot summary.
    public var displayRoot: String {
        let path = root.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public var configURL: URL { root.appending(path: "config.json") }
    public var databaseURL: URL { root.appending(path: "db.sqlite") }

    /// `db.sqlite`'s WAL sidecars. Resetting the database means deleting all
    /// three — removing only `db.sqlite` leaves a stale write-ahead log behind.
    public var databaseSidecarURLs: [URL] {
        ["-wal", "-shm"].map { root.appending(path: "db.sqlite\($0)") }
    }

    /// Resolves the host home from the environment, falling back to
    /// `~/Library/Application Support/WorkflowHost`.
    ///
    /// Purely a path computation — it touches the filesystem only to the extent
    /// `FileManager` does when locating Application Support.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HostPaths {
        if let override = environment[homeEnvironmentKey], !override.isEmpty {
            return HostPaths(root: URL(filePath: override, directoryHint: .isDirectory))
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return HostPaths(root: applicationSupport.appending(path: "WorkflowHost"))
    }

    /// Creates the home directory if it is missing.
    ///
    /// Creates the *directory* only. It never writes `config.json` — a daemon
    /// that seeds config files performs a side effect nobody asked for, and on a
    /// typo'd `WORKFLOWHOST_HOME` it would do so in the wrong place.
    public func createRootIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }
}
