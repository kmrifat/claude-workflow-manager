//
//  WorkflowTasksFile.swift
//  workflow-manager
//
//  The on-disk shape of `.taskboard/tasks.json`, and nothing else — pure
//  Foundation, no SwiftData, so the format can be exercised on its own the way
//  `MarkdownBlock` can.
//
//  Two provenance fields, because they answer different questions:
//
//  * `Envelope.writer` — who wrote *this revision of the file*. The watcher uses
//    it, together with a content hash, to recognise and drop its own echo.
//  * `TaskRow.source` — who last changed *this row*. The merge uses it to decide
//    which side's value for a field to believe.
//
//  Encoding is `.sortedKeys` and `.prettyPrinted`: a human and an agent both
//  read and hand-edit this file, and a stable byte order is what makes the echo
//  hash meaningful.
//

import Foundation

nonisolated enum WorkflowTasksFile {
    static let filename = "tasks.json"
    static let currentVersion = 1

    /// The vocabulary the agent is given. Fixed on purpose: board columns are
    /// user-renamable, so they cannot be the contract. `BoardColumn.role` maps
    /// these onto whatever the columns are actually called.
    enum Status: String, Codable, Sendable, CaseIterable {
        case todo
        case inProgress = "in_progress"
        case review
        case done
    }

    enum Writer: String, Codable, Sendable {
        case app
        case claude
    }

    struct TaskRow: Codable, Sendable, Equatable, Identifiable {
        /// `WorkItem.uuid` for cards the app owns; a fresh UUID for rows the
        /// agent files itself.
        var id: String
        var title: String
        var status: Status
        var details: String?
        var githubIssue: Int?
        var branch: String?
        var prUrl: String?
        /// The user pressed "Send to Claude" on this card. App-owned — the
        /// agent reads it to find work and never sets it.
        var requested: Bool
        /// The board column's real name. Advisory, for a human reading the
        /// file; `status` is what actually maps back.
        var column: String?
        var updatedAt: Date
        var source: Writer

        init(
            id: String,
            title: String,
            status: Status,
            details: String? = nil,
            githubIssue: Int? = nil,
            branch: String? = nil,
            prUrl: String? = nil,
            requested: Bool = false,
            column: String? = nil,
            updatedAt: Date,
            source: Writer
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.details = details
            self.githubIssue = githubIssue
            self.branch = branch
            self.prUrl = prUrl
            self.requested = requested
            self.column = column
            self.updatedAt = updatedAt
            self.source = source
        }

        /// Tolerant on the way in. Everything the agent writes is untrusted:
        /// an unrecognised status or a missing timestamp must not take the
        /// board down, so both fall back rather than throwing the file out.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            status = (try? container.decode(Status.self, forKey: .status)) ?? .todo
            details = try? container.decodeIfPresent(String.self, forKey: .details)
            githubIssue = try? container.decodeIfPresent(Int.self, forKey: .githubIssue)
            branch = try? container.decodeIfPresent(String.self, forKey: .branch)
            prUrl = try? container.decodeIfPresent(String.self, forKey: .prUrl)
            requested = (try? container.decode(Bool.self, forKey: .requested)) ?? false
            column = try? container.decodeIfPresent(String.self, forKey: .column)
            updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? .now
            source = (try? container.decode(Writer.self, forKey: .source)) ?? .claude
        }
    }

    /// A card the user deleted. Kept so an agent holding stale state cannot
    /// resurrect it on its next write.
    struct Tombstone: Codable, Sendable, Equatable {
        var id: String
        var deletedAt: Date
    }

    struct ProjectRef: Codable, Sendable, Equatable {
        var uuid: String
        var name: String
        var repo: String?
    }

    struct Envelope: Codable, Sendable, Equatable {
        var version: Int
        var project: ProjectRef
        /// Written out so the agent can read the vocabulary back rather than
        /// being told it out of band.
        var statuses: [Status]
        var updatedAt: Date
        var writer: Writer
        var tasks: [TaskRow]
        var tombstones: [Tombstone]

        init(
            version: Int = WorkflowTasksFile.currentVersion,
            project: ProjectRef,
            statuses: [Status] = Status.allCases,
            updatedAt: Date,
            writer: Writer,
            tasks: [TaskRow],
            tombstones: [Tombstone] = []
        ) {
            self.version = version
            self.project = project
            self.statuses = statuses
            self.updatedAt = updatedAt
            self.writer = writer
            self.tasks = tasks
            self.tombstones = tombstones
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decode(Int.self, forKey: .version))
                ?? WorkflowTasksFile.currentVersion
            project = try container.decode(ProjectRef.self, forKey: .project)
            statuses = (try? container.decode([Status].self, forKey: .statuses)) ?? Status.allCases
            updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? .now
            writer = (try? container.decode(Writer.self, forKey: .writer)) ?? .claude
            tasks = (try? container.decode([TaskRow].self, forKey: .tasks)) ?? []
            tombstones = (try? container.decode([Tombstone].self, forKey: .tombstones)) ?? []
        }

        /// Written by a version of the app that knows more than we do. Neither
        /// applying nor overwriting is safe.
        var isFromNewerVersion: Bool { version > WorkflowTasksFile.currentVersion }
    }

    // MARK: - Codec

    static func decode(_ data: Data) throws -> Envelope {
        try decoder.decode(Envelope.self, from: data)
    }

    static func encode(_ envelope: Envelope) throws -> Data {
        try encoder.encode(envelope)
    }

    static func read(at url: URL) throws -> Envelope {
        try decode(Data(contentsOf: url))
    }

    /// Writes atomically and returns the exact bytes, so the caller can teach
    /// the watcher to ignore the change it is about to observe.
    @discardableResult
    static func write(_ envelope: Envelope, to url: URL) throws -> Data {
        let data = try encode(envelope)
        try data.write(to: url, options: .atomic)
        return data
    }

    /// Tombstones stop being useful once no agent could plausibly still hold
    /// the deleted row.
    static let tombstoneLifetime: TimeInterval = 7 * 24 * 60 * 60

    static func pruningTombstones(_ tombstones: [Tombstone], now: Date) -> [Tombstone] {
        tombstones.filter { now.timeIntervalSince($0.deletedAt) < tombstoneLifetime }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
