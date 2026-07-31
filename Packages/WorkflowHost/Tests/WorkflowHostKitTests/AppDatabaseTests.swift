import Foundation
import GRDB
import Testing
@testable import WorkflowHostKit

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test("opening creates the database file")
    func opensAndCreatesFile() throws {
        let home = try TempHome()
        _ = try AppDatabase(paths: home.paths)

        #expect(FileManager.default.fileExists(
            atPath: home.paths.databaseURL.path(percentEncoded: false)))
    }

    @Test("journal mode is WAL")
    func journalModeIsWAL() throws {
        let home = try TempHome()
        let database = try AppDatabase(paths: home.paths)

        #expect(try database.journalMode() == "wal")
    }

    @Test("migration creates exactly the documented schema")
    func schemaMatchesTheBuildPlan() throws {
        let home = try TempHome()
        let database = try AppDatabase(paths: home.paths)

        let applied = try database.migrate()
        #expect(applied == ["v1_initialSchema"])

        let inventory = try database.schemaInventory()
        #expect(inventory.tables == ["cache", "events", "runs"])
        #expect(inventory.indexes == ["idx_events_at", "idx_runs_status"])
    }

    @Test("migrating twice is a no-op")
    func migrationIsIdempotent() throws {
        let home = try TempHome()
        let database = try AppDatabase(paths: home.paths)

        #expect(try database.migrate() == ["v1_initialSchema"])
        #expect(try database.migrate() == ["v1_initialSchema"])
        #expect(try database.schemaInventory().tables == ["cache", "events", "runs"])
    }

    @Test("columns match the documented DDL")
    func columnsMatchTheDDL() throws {
        let home = try TempHome()
        let database = try AppDatabase(paths: home.paths)
        try database.migrate()

        let columns = try database.reader.read { db in
            try ["runs", "events", "cache"].reduce(into: [String: [String]]()) { result, table in
                result[table] = try db.columns(in: table).map(\.name)
            }
        }

        #expect(columns["runs"] == [
            "id", "repo", "issue_number", "area", "branch", "worktree_path",
            "session_id", "pid", "status", "started_at", "ended_at", "exit_code",
        ])
        #expect(columns["events"] == ["id", "run_id", "at", "kind", "detail"])
        #expect(columns["cache"] == ["key", "value", "fetched_at"])
    }

    /// The build plan's correctness test: deleting the database must lose run
    /// history and nothing else.
    @Test("deleting the database loses run history and nothing else")
    func databaseIsDisposable() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig("""
            { "maxConcurrentPerRepo": 2, "pollIntervalSec": 60, "repos": [
              { "owner": "me", "name": "product-a", "path": "\(repoPath)",
                "projectNumber": 3, "readyColumn": "Ready",
                "activeColumn": "In progress", "reviewColumn": "Review" }
            ] }
            """)

        do {
            let database = try AppDatabase(paths: home.paths)
            try database.migrate()
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO runs (repo, issue_number, status) VALUES ('me/product-a', 7, 'running')
                    """)
                try db.execute(sql: """
                    INSERT INTO events (run_id, at, kind, detail)
                    VALUES (last_insert_rowid(), 1700000000, 'dispatched', NULL)
                    """)
                try db.execute(sql: """
                    INSERT INTO cache (key, value, fetched_at)
                    VALUES ('issues:me/product-a', '[]', 1700000000)
                    """)
            }
            #expect(try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM runs") } == 1)
        }

        try home.deleteDatabase()

        // Everything the database held is re-derivable; nothing else lived there.
        let rebuilt = try AppDatabase(paths: home.paths)
        try rebuilt.migrate()
        let counts = try rebuilt.reader.read { db in
            try ["runs", "events", "cache"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts == [0, 0, 0])

        // The config survived, because config never lives in the database.
        let config = try ConfigLoader.load(at: home.paths.configURL)
        #expect(config.repos.map(\.id) == ["me/product-a"])
    }

    @Test("foreign keys are enforced, so events outlive no run")
    func foreignKeysEnforced() throws {
        let home = try TempHome()
        let database = try AppDatabase(paths: home.paths)
        try database.migrate()

        // Documented consequence of keeping the DDL verbatim: events reference
        // runs with no ON DELETE clause, so a run cannot be deleted underneath
        // its events. Phase 6 deletes events first, or adds a cascade migration.
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO events (run_id, at, kind) VALUES (999, 1700000000, 'dispatched')
                    """)
            }
        }
    }
}
