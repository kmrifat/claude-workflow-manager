import GRDB

extension AppDatabase {
    /// Schema history.
    ///
    /// Migrations are raw SQL on purpose. The DDL text is the contract — it is
    /// what the build plan specifies and what `sqlite3 db.sqlite '.schema'` is
    /// checked against. Do not restate it through the schema DSL.
    ///
    /// Note that GRDB enables `PRAGMA foreign_keys = ON`, and `events.run_id` has
    /// no `ON DELETE` clause, so `DELETE FROM runs` fails while the run still has
    /// events. Delete events first. Adding `ON DELETE CASCADE` would be a
    /// deliberate future migration, not a silent edit to this one.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initialSchema") { db in
            try db.execute(sql: """
                CREATE TABLE runs (
                  id INTEGER PRIMARY KEY,
                  repo TEXT NOT NULL,
                  issue_number INTEGER NOT NULL,
                  area TEXT,
                  branch TEXT,
                  worktree_path TEXT,
                  session_id TEXT,
                  pid INTEGER,
                  status TEXT NOT NULL,
                  started_at INTEGER,
                  ended_at INTEGER,
                  exit_code INTEGER
                )
                """)

            try db.execute(sql: """
                CREATE TABLE events (
                  id INTEGER PRIMARY KEY,
                  run_id INTEGER REFERENCES runs(id),
                  at INTEGER NOT NULL,
                  kind TEXT NOT NULL,
                  detail TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE cache (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL,
                  fetched_at INTEGER NOT NULL
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_runs_status ON runs(status)")
            try db.execute(sql: "CREATE INDEX idx_events_at ON events(at DESC)")
        }

        return migrator
    }
}
