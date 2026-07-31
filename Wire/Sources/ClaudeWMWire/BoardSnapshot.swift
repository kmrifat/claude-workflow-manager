//
//  BoardSnapshot.swift
//  ClaudeWMWire
//
//  A whole project board, flattened into values. This is what the phone renders
//  and the only thing it is ever given — it holds no model of its own.
//
//  Two shapes deliberately *not* reused from the app:
//
//  * `Priority` is an `Int` in SwiftData (`priorityRaw`), where the number is an
//    ordering artifact. On the wire it is a string, so a reordered enum cannot
//    silently reinterpret every card, and so a human reading a frame can tell
//    what it says.
//  * `WorkflowTasksFile.Writer` does not appear here at all. Its decoder maps an
//    unrecognised writer to `.claude`, and `.claude` owns `status`, `branch` and
//    `prUrl` in the merge — so a phone that named itself as a writer would
//    quietly acquire the agent's field ownership. The phone is not a writer of
//    that file. It asks the Mac to mutate, and the Mac's existing sync writes.
//

import Foundation

/// Which project a frame is about. `repoSlug` is advisory — for display, never
/// for matching.
public struct WireProjectRef: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var repoSlug: String?

    public init(id: String, name: String, repoSlug: String? = nil) {
        self.id = id
        self.name = name
        self.repoSlug = repoSlug
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        repoSlug = try? container.decodeIfPresent(String.self, forKey: .repoSlug)
    }
}

/// The fixed vocabulary a column can be mapped onto, mirroring `ColumnRole` in
/// the app and the four statuses in `.taskboard/tasks.json`. Columns are
/// user-renamable, so the name can never be the contract.
public enum WireColumnRole: String, Codable, Sendable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case review
    case done
}

/// Ordered low to urgent, and `Comparable` on that order rather than on the
/// raw string — sorting by the wire spelling would put "high" before "normal".
public enum WirePriority: String, Codable, Sendable, CaseIterable, Comparable {
    case low
    case normal
    case high
    case urgent

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order = Self.allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct WireCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var details: String
    public var priority: WirePriority
    public var owner: String?
    public var startDate: Date?
    public var dueDate: Date?
    public var tags: [String]
    public var isDone: Bool

    public var githubIssue: Int?
    public var githubRepoSlug: String?

    /// Agent-owned on the Mac side. Read-only here: the phone displays these,
    /// and the mutation vocabulary has no way to set them.
    public var branch: String?
    public var prURL: String?
    public var requested: Bool

    /// Ids of cards that must finish first. Sent so the phone can grey a blocked
    /// card and refuse to send it to Claude, matching the Mac's rule.
    public var blockedBy: [String]
    public var subtaskCount: Int
    public var subtasksDone: Int
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        details: String = "",
        priority: WirePriority = .normal,
        owner: String? = nil,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        tags: [String] = [],
        isDone: Bool = false,
        githubIssue: Int? = nil,
        githubRepoSlug: String? = nil,
        branch: String? = nil,
        prURL: String? = nil,
        requested: Bool = false,
        blockedBy: [String] = [],
        subtaskCount: Int = 0,
        subtasksDone: Int = 0,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.owner = owner
        self.startDate = startDate
        self.dueDate = dueDate
        self.tags = tags
        self.isDone = isDone
        self.githubIssue = githubIssue
        self.githubRepoSlug = githubRepoSlug
        self.branch = branch
        self.prURL = prURL
        self.requested = requested
        self.blockedBy = blockedBy
        self.subtaskCount = subtaskCount
        self.subtasksDone = subtasksDone
        self.updatedAt = updatedAt
    }

    /// Tolerant on the way in, for the same reason `WorkflowTasksFile.TaskRow`
    /// is: one unrecognised priority from a newer Mac must not blank the board
    /// on a phone that cannot be updated as easily.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        details = (try? container.decode(String.self, forKey: .details)) ?? ""
        priority = (try? container.decode(WirePriority.self, forKey: .priority)) ?? .normal
        owner = try? container.decodeIfPresent(String.self, forKey: .owner)
        startDate = try? container.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try? container.decodeIfPresent(Date.self, forKey: .dueDate)
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        isDone = (try? container.decode(Bool.self, forKey: .isDone)) ?? false
        githubIssue = try? container.decodeIfPresent(Int.self, forKey: .githubIssue)
        githubRepoSlug = try? container.decodeIfPresent(String.self, forKey: .githubRepoSlug)
        branch = try? container.decodeIfPresent(String.self, forKey: .branch)
        prURL = try? container.decodeIfPresent(String.self, forKey: .prURL)
        requested = (try? container.decode(Bool.self, forKey: .requested)) ?? false
        blockedBy = (try? container.decode([String].self, forKey: .blockedBy)) ?? []
        subtaskCount = (try? container.decode(Int.self, forKey: .subtaskCount)) ?? 0
        subtasksDone = (try? container.decode(Int.self, forKey: .subtasksDone)) ?? 0
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
    }

    /// Mirrors `WorkItem.isBlocked`, but only as far as the ids allow — whether
    /// a blocker is *done* is a question about another card, so the snapshot
    /// answers it rather than the card.
    public func isBlocked(in cards: [String: WireCard]) -> Bool {
        blockedBy.contains { cards[$0]?.isDone == false }
    }
}

public struct WireColumn: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var role: WireColumnRole?
    public var wipLimit: Int?
    public var isCompletionColumn: Bool
    /// In board order. Order is carried by position, never by a sort key: the
    /// Mac's `FractionalOrder` doubles are an implementation detail and would
    /// only give the phone a way to disagree.
    public var cards: [WireCard]

    public init(
        id: String,
        name: String,
        role: WireColumnRole? = nil,
        wipLimit: Int? = nil,
        isCompletionColumn: Bool = false,
        cards: [WireCard] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.wipLimit = wipLimit
        self.isCompletionColumn = isCompletionColumn
        self.cards = cards
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        // An unknown role means "a column this peer has no mapping for", which
        // is exactly what `nil` already means. No third state needed.
        role = try? container.decodeIfPresent(WireColumnRole.self, forKey: .role)
        wipLimit = try? container.decodeIfPresent(Int.self, forKey: .wipLimit)
        isCompletionColumn = (try? container.decode(Bool.self, forKey: .isCompletionColumn)) ?? false
        cards = (try? container.decode([WireCard].self, forKey: .cards)) ?? []
    }
}

public struct BoardSnapshot: Codable, Sendable, Equatable {
    public var project: WireProjectRef
    public var columns: [WireColumn]
    /// The Mac's `boardRevision` hash at capture. The phone echoes it back so
    /// the Mac can tell a stale client from a current one, and so an `event`
    /// need only carry a number rather than the whole board.
    public var revision: Int
    public var capturedAt: Date

    public init(
        project: WireProjectRef,
        columns: [WireColumn],
        revision: Int,
        capturedAt: Date
    ) {
        self.project = project
        self.columns = columns
        self.revision = revision
        self.capturedAt = capturedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(WireProjectRef.self, forKey: .project)
        columns = (try? container.decode([WireColumn].self, forKey: .columns)) ?? []
        revision = (try? container.decode(Int.self, forKey: .revision)) ?? 0
        capturedAt = (try? container.decode(Date.self, forKey: .capturedAt)) ?? .distantPast
    }

    /// Every card by id, for the blocker lookup and for diffing against a
    /// previous snapshot.
    public var cardsByID: [String: WireCard] {
        Dictionary(
            columns.flatMap(\.cards).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
