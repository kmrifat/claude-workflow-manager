import Foundation
import GRDB
import WorkflowCore

/// Reads and writes `runs` and `events`.
///
/// A `Sendable` struct over `AppDatabase`, not an actor — GRDB owns the
/// serialization (see the concurrency rule in CLAUDE.md). Multi-step invariants
/// go inside one `write { }` rather than across two `await`s.
public struct RunStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Writes

    /// Inserts a run and its `dispatched` event in one transaction — a run that
    /// exists with no record of having started is a lie the dashboard would show.
    public func createRun(
        repo: String,
        issueNumber: Int,
        area: String?,
        branch: String?,
        worktreePath: String?,
        status: RunStatus = .running,
        at now: Date = Date()
    ) throws -> Int64 {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (repo, issue_number, area, branch, worktree_path, status, started_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [repo, issueNumber, area, branch, worktreePath,
                            status.rawValue, Int64(now.timeIntervalSince1970)]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO events (run_id, at, kind, detail) VALUES (?, ?, ?, ?)",
                arguments: [id, Int64(now.timeIntervalSince1970),
                            EventKind.dispatched.rawValue, "\(repo)#\(issueNumber)"]
            )
            return id
        }
    }

    public func attachSession(runId: Int64, sessionId: String?, pid: Int32?) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE runs SET session_id = ?, pid = ? WHERE id = ?",
                arguments: [sessionId, pid.map { Int($0) }, runId]
            )
        }
    }

    public func setBranch(runId: Int64, branch: String, worktreePath: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE runs SET branch = ?, worktree_path = ? WHERE id = ?",
                arguments: [branch, worktreePath, runId]
            )
        }
    }

    /// Moves a run to a terminal or review state and records why, atomically.
    public func finish(
        runId: Int64,
        status: RunStatus,
        exitCode: Int32?,
        event: EventKind,
        detail: String?,
        at now: Date = Date()
    ) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE runs SET status = ?, ended_at = ?, exit_code = ? WHERE id = ?",
                arguments: [status.rawValue, Int64(now.timeIntervalSince1970),
                            exitCode.map { Int($0) }, runId]
            )
            try db.execute(
                sql: "INSERT INTO events (run_id, at, kind, detail) VALUES (?, ?, ?, ?)",
                arguments: [runId, Int64(now.timeIntervalSince1970), event.rawValue, detail]
            )
        }
    }

    public func recordEvent(
        runId: Int64?,
        kind: EventKind,
        detail: String?,
        at now: Date = Date()
    ) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO events (run_id, at, kind, detail) VALUES (?, ?, ?, ?)",
                arguments: [runId, Int64(now.timeIntervalSince1970), kind.rawValue, detail]
            )
        }
    }

    // MARK: - Reads

    public func run(id: Int64) throws -> RunRecord? {
        try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [id])
                .map(RunRecord.init(row:))
        }
    }

    public func runs(status: RunStatus) throws -> [RunRecord] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM runs WHERE status = ? ORDER BY started_at DESC",
                arguments: [status.rawValue]
            ).map(RunRecord.init(row:))
        }
    }

    /// Runs still occupying a slot. `review` counts — the human is the
    /// bottleneck, and a PR awaiting review is still work in flight.
    public func activeRuns(repo: String? = nil) throws -> [RunRecord] {
        try database.reader.read { db in
            let sql = """
                SELECT * FROM runs
                WHERE status IN ('queued', 'running')
                \(repo == nil ? "" : "AND repo = ?")
                ORDER BY started_at DESC
                """
            let arguments: StatementArguments = repo.map { [$0] } ?? []
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(RunRecord.init(row:))
        }
    }

    public func allRuns(limit: Int = 200) throws -> [RunRecord] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM runs ORDER BY COALESCE(started_at, 0) DESC LIMIT ?",
                arguments: [limit]
            ).map(RunRecord.init(row:))
        }
    }

    public func recentEvents(limit: Int = 100) throws -> [EventRecord] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM events ORDER BY at DESC, id DESC LIMIT ?",
                arguments: [limit]
            ).map(EventRecord.init(row:))
        }
    }

    public func events(runId: Int64) throws -> [EventRecord] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM events WHERE run_id = ? ORDER BY at DESC, id DESC",
                arguments: [runId]
            ).map(EventRecord.init(row:))
        }
    }
}

// MARK: - Row decoding
//
// Hand-written rather than FetchableRecord conformances on the DTOs: the DTOs
// live in WorkflowCore, which must not depend on GRDB — the clients link it too.

extension RunRecord {
    init(row: Row) {
        self.init(
            id: row["id"],
            repo: row["repo"],
            issueNumber: row["issue_number"],
            area: row["area"],
            branch: row["branch"],
            worktreePath: row["worktree_path"],
            sessionId: row["session_id"],
            pid: (row["pid"] as Int?).map(Int32.init),
            // An unrecognised status in the column shouldn't crash the
            // dashboard; treat it as failed and let it be visible.
            status: RunStatus(rawValue: row["status"]) ?? .failed,
            startedAt: (row["started_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            endedAt: (row["ended_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            exitCode: (row["exit_code"] as Int?).map(Int32.init)
        )
    }
}

extension EventRecord {
    init(row: Row) {
        self.init(
            id: row["id"],
            runId: row["run_id"],
            at: Date(timeIntervalSince1970: TimeInterval(row["at"] as Int64)),
            kind: EventKind(rawValue: row["kind"]) ?? .blocked,
            detail: row["detail"]
        )
    }
}
