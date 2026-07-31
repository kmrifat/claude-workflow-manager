import Foundation
import GRDB
import WorkflowCore

/// Typed access to the generic `cache` table.
///
/// Everything here is a timestamped copy of something GitHub owns. Nothing in
/// this table is authoritative, and nothing that cannot be re-fetched may be
/// stored in it — that is what makes `db.sqlite` disposable.
public struct CacheStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Cache keys. One namespace per kind of object, scoped to `owner/name`.
    public enum Key {
        public static func repository(_ repo: RepoConfig) -> String { "repo:\(repo.id)" }
        public static func issues(_ repo: RepoConfig) -> String { "issues:\(repo.id)" }
        public static func pullRequests(_ repo: RepoConfig) -> String { "pulls:\(repo.id)" }
        public static func project(_ repo: RepoConfig) -> String { "project:\(repo.id)" }
    }

    public func read<Value: Codable & Sendable>(
        _ key: String,
        as type: Value.Type = Value.self
    ) throws -> CacheEntry<Value>? {
        let row = try database.reader.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value, fetched_at FROM cache WHERE key = ?",
                arguments: [key]
            )
        }
        guard let row else { return nil }

        let json: String = row["value"]
        let fetchedAt = Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64))
        let envelope = try Self.decoder.decode(
            Envelope<Value>.self, from: Data(json.utf8)
        )
        return CacheEntry(value: envelope.value, etag: envelope.etag, fetchedAt: fetchedAt)
    }

    public func write<Value: Codable & Sendable>(
        _ key: String,
        value: Value,
        etag: String?,
        at fetchedAt: Date
    ) throws {
        let json = String(
            decoding: try Self.encoder.encode(Envelope(etag: etag, value: value)),
            as: UTF8.self
        )
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache (key, value, fetched_at) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, fetched_at = excluded.fetched_at
                    """,
                arguments: [key, json, Int64(fetchedAt.timeIntervalSince1970)]
            )
        }
    }

    /// Marks an entry as still current without rewriting it — what a 304 means.
    public func touch(_ key: String, at fetchedAt: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE cache SET fetched_at = ? WHERE key = ?",
                arguments: [Int64(fetchedAt.timeIntervalSince1970), key]
            )
        }
    }

    public func fetchedAt(_ key: String) throws -> Date? {
        try database.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT fetched_at FROM cache WHERE key = ?", arguments: [key])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

    /// The ETag alongside the cached value, so a conditional request can be made
    /// without decoding the payload.
    ///
    /// Storing the ETag *inside* the value JSON is deliberate: the build plan
    /// keeps one generic cache table precisely to avoid a migration every time
    /// something new needs caching, and an `etag` column would be one.
    private struct Envelope<Value: Codable & Sendable>: Codable, Sendable {
        let etag: String?
        let value: Value
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct CacheEntry<Value: Sendable>: Sendable {
    public let value: Value
    public let etag: String?
    public let fetchedAt: Date

    public init(value: Value, etag: String?, fetchedAt: Date) {
        self.value = value
        self.etag = etag
        self.fetchedAt = fetchedAt
    }

    public var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
}
