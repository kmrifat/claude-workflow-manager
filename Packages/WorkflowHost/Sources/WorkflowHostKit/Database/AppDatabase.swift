import Foundation
import GRDB

/// The host's SQLite database.
///
/// **This is a `Sendable final class`, never an `actor`.** GRDB's `DatabasePool`
/// already serializes writes and runs readers concurrently under WAL; wrapping it
/// in an actor would add a second queue in front of one that exists, cost a hop,
/// and re-serialize exactly the concurrent reads that made `DatabasePool` the
/// right choice. It would also give *false* atomicity — actors are reentrant, so
/// two `await`s in a row are not one operation. `write { db in … }` is
/// synchronous and cannot `await`; that is the real atomicity boundary.
///
/// Every subsystem — poller, dispatcher, HTTP handlers — holds this same instance
/// and calls it directly. See CLAUDE.md, "Concurrency rule".
///
/// The database is disposable: it holds run history, events, and a re-derivable
/// cache. Deleting it must lose run history and nothing else.
public final class AppDatabase: Sendable {
    public let writer: DatabasePool

    /// Reads go through the pool's concurrent reader connections.
    public var reader: any DatabaseReader { writer }

    public init(path: String) throws {
        var configuration = Configuration()
        // GRDB defaults to `.immediateError`. WAL is multi-process, so a second
        // accidental `swift run WorkflowHost` or an open `sqlite3` session would
        // otherwise make writes fail the instant they contend.
        configuration.busyMode = .timeout(5)

        // DatabasePool's initializer sets up WAL itself; journalMode is left alone.
        writer = try DatabasePool(path: path, configuration: configuration)
    }

    public convenience init(paths: HostPaths) throws {
        try self.init(path: paths.databaseURL.path(percentEncoded: false))
    }

    /// Applies any migrations not yet recorded. Idempotent.
    @discardableResult
    public func migrate() throws -> [String] {
        let migrator = Self.migrator
        try migrator.migrate(writer)
        return try reader.read { db in
            try migrator.appliedIdentifiers(db).sorted()
        }
    }

    /// The journal mode SQLite actually settled on. Expected to be `wal`.
    public func journalMode() throws -> String {
        try reader.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }

    /// The tables and indexes that exist, excluding SQLite's own bookkeeping and
    /// GRDB's migration table. Used to check the schema against the build plan.
    public func schemaInventory() throws -> (tables: [String], indexes: [String]) {
        try reader.read { db in
            func names(ofType type: String) throws -> [String] {
                try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = ? AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
                    ORDER BY name
                    """, arguments: [type])
            }
            return (tables: try names(ofType: "table"), indexes: try names(ofType: "index"))
        }
    }
}
