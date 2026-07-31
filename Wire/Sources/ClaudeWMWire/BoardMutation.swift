//
//  BoardMutation.swift
//  ClaudeWMWire
//
//  What a phone is allowed to ask the Mac to do. An *intent*, not a diff: the
//  phone says "move this card to that column at index 2", never "here is the
//  board, make it look like this". A whole-board write is how two clients
//  clobber each other, and it is the mistake `WorkflowMerge` exists to avoid on
//  the file side.
//
//  The vocabulary is deliberately small, and deliberately excludes `branch` and
//  `prUrl`. Those are Claude's fields — the agent is the only party that
//  observes them — so there is no wire spelling that could set them.
//

import Foundation

public enum BoardMutation: Sendable, Equatable {
    case createCard(columnID: String, title: String, details: String)
    case moveCard(cardID: String, toColumnID: String, index: Int)
    case setTitle(cardID: String, title: String)
    case setDetails(cardID: String, details: String)
    case setPriority(cardID: String, priority: WirePriority)
    case setRequested(cardID: String, requested: Bool)
    case deleteCard(cardID: String)

    /// A mutation this build has no code for, kept as data.
    ///
    /// Decoding must not throw here. A newer phone will invent verbs, and the
    /// Mac's answer has to be a refusal it can show the user — not a dropped
    /// connection, which looks identical to the Mac having gone to sleep.
    case unrecognized(kind: String)

    /// The wire spelling. Strings, not integers: a renumbered enum silently
    /// reinterpreting `deleteCard` as `setTitle` is not a failure mode worth
    /// having.
    public var kind: String {
        switch self {
        case .createCard:   "createCard"
        case .moveCard:     "moveCard"
        case .setTitle:     "setTitle"
        case .setDetails:   "setDetails"
        case .setPriority:  "setPriority"
        case .setRequested: "setRequested"
        case .deleteCard:   "deleteCard"
        case .unrecognized(let kind): kind
        }
    }

    /// The card a mutation is about, where there is one. `createCard` has none
    /// yet — the Mac mints the id, so that two phones offline at once cannot
    /// produce the same one.
    public var cardID: String? {
        switch self {
        case .createCard, .unrecognized:      nil
        case .moveCard(let id, _, _):         id
        case .setTitle(let id, _):            id
        case .setDetails(let id, _):          id
        case .setPriority(let id, _):         id
        case .setRequested(let id, _):        id
        case .deleteCard(let id):             id
        }
    }
}

extension BoardMutation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, cardID, columnID, title, details, priority, index, requested
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(cardID, forKey: .cardID)

        switch self {
        case .createCard(let columnID, let title, let details):
            try container.encode(columnID, forKey: .columnID)
            try container.encode(title, forKey: .title)
            try container.encode(details, forKey: .details)
        case .moveCard(_, let toColumnID, let index):
            try container.encode(toColumnID, forKey: .columnID)
            try container.encode(index, forKey: .index)
        case .setTitle(_, let title):
            try container.encode(title, forKey: .title)
        case .setDetails(_, let details):
            try container.encode(details, forKey: .details)
        case .setPriority(_, let priority):
            try container.encode(priority, forKey: .priority)
        case .setRequested(_, let requested):
            try container.encode(requested, forKey: .requested)
        case .deleteCard, .unrecognized:
            break
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        // A required field that is missing or the wrong type makes the mutation
        // meaningless, not merely unknown — fall back to `unrecognized` so the
        // Mac reports one refusal rather than applying half of it.
        func string(_ key: CodingKeys) -> String? {
            try? container.decode(String.self, forKey: key)
        }

        switch kind {
        case "createCard":
            guard let columnID = string(.columnID) else { break }
            self = .createCard(
                columnID: columnID,
                title: string(.title) ?? "",
                details: string(.details) ?? ""
            )
            return
        case "moveCard":
            guard let cardID = string(.cardID), let columnID = string(.columnID) else { break }
            self = .moveCard(
                cardID: cardID,
                toColumnID: columnID,
                // A missing index means "the end", which is what `append` does.
                index: (try? container.decode(Int.self, forKey: .index)) ?? Int.max
            )
            return
        case "setTitle":
            guard let cardID = string(.cardID), let title = string(.title) else { break }
            self = .setTitle(cardID: cardID, title: title)
            return
        case "setDetails":
            guard let cardID = string(.cardID), let details = string(.details) else { break }
            self = .setDetails(cardID: cardID, details: details)
            return
        case "setPriority":
            guard let cardID = string(.cardID),
                  let priority = try? container.decode(WirePriority.self, forKey: .priority)
            else { break }
            self = .setPriority(cardID: cardID, priority: priority)
            return
        case "setRequested":
            guard let cardID = string(.cardID),
                  let requested = try? container.decode(Bool.self, forKey: .requested)
            else { break }
            self = .setRequested(cardID: cardID, requested: requested)
            return
        case "deleteCard":
            guard let cardID = string(.cardID) else { break }
            self = .deleteCard(cardID: cardID)
            return
        default:
            break
        }
        self = .unrecognized(kind: kind)
    }
}

/// One mutation, addressed and identified.
///
/// `id` is the client's, and comes back on the acknowledgement. It exists so a
/// phone that retries after a dropped connection can tell "applied twice" from
/// "applied once" — a retried `createCard` is otherwise indistinguishable from
/// the user tapping add twice.
///
/// **Replies are not in request order, and there is not one per request.** A
/// mutation produces an `ack` *and* a broadcast `event`, and events for other
/// people's edits arrive whenever they happen. A client that reads "the next
/// message" as "the reply" will read the previous mutation's event as this
/// one's answer and be wrong from then on — quietly, because both are valid
/// frames. Match on this id.
public struct MutationRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectID: String
    public var mutation: BoardMutation

    public init(id: String, projectID: String, mutation: BoardMutation) {
        self.id = id
        self.projectID = projectID
        self.mutation = mutation
    }
}
