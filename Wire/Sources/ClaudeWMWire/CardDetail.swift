//
//  CardDetail.swift
//  ClaudeWMWire
//
//  What the phone needs to show a card the way the Mac's card window does,
//  beyond what a board snapshot carries: its subtasks by id, its activity, its
//  images, and how far Claude has got. Asked for one card at a time
//  (`requestCard`) rather than packed into every snapshot, because a board of
//  forty cards each carrying twenty events is a lot to resend for one move.
//
//  Also the overview the phone's Home shows, and image transfer in both
//  directions. Everything here is additive: an older Mac answers the new
//  messages as unrecognised, and an older phone never sends them.
//

import Foundation

// MARK: - A card in full

public struct WireSubtask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var done: Bool

    public init(id: String, title: String, done: Bool) {
        self.id = id
        self.title = title
        self.done = done
    }
}

/// One line of a card's activity: who did what, and the note if one was left.
public struct WireActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var date: Date
    public var actor: String
    /// The MCP tool, when an agent made the change. Absent for a person.
    public var tool: String?
    public var summary: String
    public var note: String?

    public init(id: String, date: Date, actor: String, tool: String? = nil, summary: String, note: String? = nil) {
        self.id = id
        self.date = date
        self.actor = actor
        self.tool = tool
        self.summary = summary
        self.note = note
    }
}

/// An image the card's notes refer to (`![name](attachment:<id>)`). The bytes
/// are fetched separately, by id, when the phone wants to draw it.
public struct WireAttachmentRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var contentType: String
    public var width: Int
    public var height: Int
    public var byteCount: Int

    public init(id: String, name: String, contentType: String, width: Int, height: Int, byteCount: Int) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }
}

/// How far Claude has got with a card. The Mac works it out from the card's
/// request flag and its column, exactly as its own board does, so the two never
/// disagree about whether Claude is "working".
public enum WireAgentState: String, Codable, Sendable {
    case none
    case queued
    case working
    case inReview
    case done
}

public struct WireCardDetail: Codable, Sendable, Equatable {
    public var projectID: String
    public var card: WireCard
    public var columnID: String
    public var subtasks: [WireSubtask]
    /// Newest first.
    public var activity: [WireActivity]
    public var attachments: [WireAttachmentRef]
    public var agentState: WireAgentState
    public var agentName: String?
    public var claimedAt: Date?
    public var createdAt: Date

    public init(
        projectID: String,
        card: WireCard,
        columnID: String,
        subtasks: [WireSubtask] = [],
        activity: [WireActivity] = [],
        attachments: [WireAttachmentRef] = [],
        agentState: WireAgentState = .none,
        agentName: String? = nil,
        claimedAt: Date? = nil,
        createdAt: Date
    ) {
        self.projectID = projectID
        self.card = card
        self.columnID = columnID
        self.subtasks = subtasks
        self.activity = activity
        self.attachments = attachments
        self.agentState = agentState
        self.agentName = agentName
        self.claimedAt = claimedAt
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        card = try container.decode(WireCard.self, forKey: .card)
        columnID = (try? container.decode(String.self, forKey: .columnID)) ?? ""
        subtasks = (try? container.decode([WireSubtask].self, forKey: .subtasks)) ?? []
        activity = (try? container.decode([WireActivity].self, forKey: .activity)) ?? []
        attachments = (try? container.decode([WireAttachmentRef].self, forKey: .attachments)) ?? []
        agentState = (try? container.decode(WireAgentState.self, forKey: .agentState)) ?? .none
        agentName = try? container.decodeIfPresent(String.self, forKey: .agentName)
        claimedAt = try? container.decodeIfPresent(Date.self, forKey: .claimedAt)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? .distantPast
    }
}

// MARK: - Overview

/// One card in a smart list, with enough to draw a row without its board.
public struct WireQueueItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { cardID }
    public var projectID: String
    public var projectName: String
    public var cardID: String
    public var title: String
    public var columnName: String
    /// The latest thing Claude said about it, or why it is in this list.
    public var detail: String?
    public var dueDate: Date?

    public init(projectID: String, projectName: String, cardID: String, title: String,
                columnName: String, detail: String? = nil, dueDate: Date? = nil) {
        self.projectID = projectID
        self.projectName = projectName
        self.cardID = cardID
        self.title = title
        self.columnName = columnName
        self.detail = detail
        self.dueDate = dueDate
    }
}

/// The Mac's three smart lists, for the phone's Home. Computed on the Mac by
/// the same rules as its own sidebar, so a count never differs between them.
public struct WireOverview: Codable, Sendable, Equatable {
    public var agents: [WireQueueItem]
    public var review: [WireQueueItem]
    public var overdue: [WireQueueItem]

    public init(agents: [WireQueueItem] = [], review: [WireQueueItem] = [], overdue: [WireQueueItem] = []) {
        self.agents = agents
        self.review = review
        self.overdue = overdue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? container.decode([WireQueueItem].self, forKey: .agents)) ?? []
        review = (try? container.decode([WireQueueItem].self, forKey: .review)) ?? []
        overdue = (try? container.decode([WireQueueItem].self, forKey: .overdue)) ?? []
    }
}

// MARK: - Images

/// A piece of an image the phone is sending for a card.
///
/// Images go in pieces because a photo is megabytes and every message is one
/// WebSocket frame — through a Cloudflare Tunnel one sealed frame — and
/// because pieces let the phone show progress. The Mac reassembles by
/// `uploadID`, checks the result really is an image, stores it on the card and
/// adds the reference to its notes.
public struct WireUploadChunk: Codable, Sendable, Equatable {
    /// Chosen by the phone; identifies one image's pieces.
    public var uploadID: String
    public var projectID: String
    public var cardID: String
    public var filename: String
    public var totalBytes: Int
    public var offset: Int
    public var data: Data
    public var isLast: Bool

    public init(uploadID: String, projectID: String, cardID: String, filename: String,
                totalBytes: Int, offset: Int, data: Data, isLast: Bool) {
        self.uploadID = uploadID
        self.projectID = projectID
        self.cardID = cardID
        self.filename = filename
        self.totalBytes = totalBytes
        self.offset = offset
        self.data = data
        self.isLast = isLast
    }
}

/// A piece of an image the Mac is sending, in answer to `requestAttachment`.
public struct WireAttachmentChunk: Codable, Sendable, Equatable {
    public var attachmentID: String
    /// The size asked for, echoed so a thumbnail and a full image fetched at
    /// once do not get mixed up. nil is full size.
    public var maxEdge: Int?
    public var contentType: String
    public var totalBytes: Int
    public var offset: Int
    public var data: Data
    public var isLast: Bool

    public init(attachmentID: String, maxEdge: Int?, contentType: String,
                totalBytes: Int, offset: Int, data: Data, isLast: Bool) {
        self.attachmentID = attachmentID
        self.maxEdge = maxEdge
        self.contentType = contentType
        self.totalBytes = totalBytes
        self.offset = offset
        self.data = data
        self.isLast = isLast
    }
}

public enum WireImageTransfer {
    /// Bytes per piece. Base64 in JSON makes a frame about a third larger.
    public static let chunkSize = 192 * 1024
    /// The largest image the Mac accepts from a phone.
    public static let maxUploadBytes = 30 * 1024 * 1024

    /// `data` cut into pieces of `chunkSize`, in order. Never empty: an empty
    /// image is still one (last) piece, so the receiver always sees an end.
    public static func pieces(of data: Data) -> [(offset: Int, data: Data, isLast: Bool)] {
        guard !data.isEmpty else { return [(0, Data(), true)] }
        var pieces: [(Int, Data, Bool)] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            pieces.append((offset, data.subdata(in: offset..<end), end == data.count))
            offset = end
        }
        return pieces
    }

    /// Collects pieces in order. Returns the whole once the last piece has
    /// arrived, nil before, and throws on a piece out of order or too much in
    /// total — a sender that skips or repeats a piece produces a corrupt image,
    /// and that is better refused than stored.
    public struct Assembler: Sendable {
        public private(set) var data = Data()
        public let expectedBytes: Int

        public init(expectedBytes: Int) {
            self.expectedBytes = expectedBytes
        }

        public enum Failure: Error, Equatable {
            case outOfOrder
            case tooLarge
            case sizeMismatch
        }

        public mutating func add(offset: Int, data piece: Data, isLast: Bool) throws -> Data? {
            guard offset == data.count else { throw Failure.outOfOrder }
            guard data.count + piece.count <= min(expectedBytes, WireImageTransfer.maxUploadBytes) else {
                throw Failure.tooLarge
            }
            data.append(piece)
            guard isLast else { return nil }
            guard data.count == expectedBytes else { throw Failure.sizeMismatch }
            return data
        }
    }
}
