import Foundation
import WorkflowCore
import WorkflowHostKit

/// A throwaway host home for one test.
///
/// Swift Testing runs tests in parallel, so the per-instance UUID is required,
/// not a nicety — a shared directory would produce cross-test WAL writes and
/// flaky failures.
final class TempHome {
    let paths: HostPaths

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wfh-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        paths = HostPaths(root: root)
        try paths.createRootIfNeeded()
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    var environment: [String: String] {
        [HostPaths.homeEnvironmentKey: paths.root.path(percentEncoded: false)]
    }

    /// Writes `config.json` verbatim, so tests can feed in malformed JSON too.
    func writeConfig(_ json: String) throws {
        try Data(json.utf8).write(to: paths.configURL)
    }

    /// A directory inside the home that passes `RepoConfig`'s "is a git repo"
    /// check, without shelling out to `git`.
    func makeRepoDirectory(named name: String) throws -> String {
        let repo = paths.root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        return repo.path(percentEncoded: false)
    }

    /// Deletes `db.sqlite` *and* its WAL sidecars. Removing only `db.sqlite`
    /// leaves a stale write-ahead log, and a reset test that skips them lies.
    func deleteDatabase() throws {
        for url in [paths.databaseURL] + paths.databaseSidecarURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A temp home with a migrated database, held together.
///
/// The pairing matters: `TempHome.deinit` deletes the directory, so a test that
/// keeps only the `CacheStore` would have the database yanked out from under it
/// and fail with a SQLite disk I/O error. Holding the fixture holds both.
struct Fixture {
    let home: TempHome
    let database: AppDatabase
    let cache: CacheStore

    init() throws {
        home = try TempHome()
        database = try AppDatabase(paths: home.paths)
        try database.migrate()
        cache = CacheStore(database: database)
    }

    func repo(_ name: String = "product-a", readyColumn: String = "Ready") throws -> RepoConfig {
        RepoConfig(
            owner: "me", name: name,
            path: try home.makeRepoDirectory(named: name),
            projectNumber: 3, readyColumn: readyColumn,
            activeColumn: "In progress", reviewColumn: "Review"
        )
    }

    func config(repos: [RepoConfig]) -> HostConfig {
        HostConfig(maxConcurrentPerRepo: 2, pollIntervalSec: 60, repos: repos)
    }
}
