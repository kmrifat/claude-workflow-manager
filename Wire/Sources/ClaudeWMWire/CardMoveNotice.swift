//
//  CardMoveNotice.swift
//  ClaudeWMWire
//
//  What a "card moved" notification says, decided once so the Mac and the phone
//  word it identically.
//
//  The wording is the reason this is shared rather than written twice. A
//  notification is read in a second, on a lock screen, out of context — so it
//  has to lead with the thing that changed and name who changed it, and getting
//  that subtly different on two platforms is exactly the kind of drift nobody
//  notices until a user mentions it.
//

import Foundation

public struct CardMoveNotice: Sendable, Equatable {
    /// Who moved it. Not cosmetic: the whole rule is that you are told about
    /// moves *you* did not make, and the actor is how each platform decides
    /// whether to stay quiet.
    public enum Origin: String, Sendable {
        case claude
        case phone
        case mac

        var actor: String {
            switch self {
            case .claude: "Claude"
            case .phone:  "your phone"
            case .mac:    "your Mac"
            }
        }
    }

    public var cardTitle: String
    public var fromColumn: String?
    public var toColumn: String
    public var projectName: String
    public var origin: Origin

    public init(
        cardTitle: String,
        fromColumn: String?,
        toColumn: String,
        projectName: String,
        origin: Origin
    ) {
        self.cardTitle = cardTitle
        self.fromColumn = fromColumn
        self.toColumn = toColumn
        self.projectName = projectName
        self.origin = origin
    }

    /// The card, not the app. A banner that says "Claude WM" tells you nothing
    /// you did not already know from the icon next to it.
    public var title: String {
        cardTitle.isEmpty ? "Untitled card" : cardTitle
    }

    /// Where it went and who moved it, in that order — the destination is the
    /// news, and "Review" or "Done" is often the whole reason you care.
    public var body: String {
        let destination = fromColumn.map { "\($0) → \(toColumn)" } ?? "Moved to \(toColumn)"
        return "\(destination) · by \(origin.actor)"
    }

    public var subtitle: String { projectName }

    /// Coalescing key. Several moves of one card land as one notification
    /// showing the latest, rather than a stack of stale ones — an agent working
    /// through a card touches it more than once.
    public var identifier: String {
        "card-move-\(projectName)-\(cardTitle)"
    }

    /// Notifications are grouped per project in Notification Centre.
    public var threadIdentifier: String { "project-\(projectName)" }
}

extension BoardSnapshot {
    /// Cards that changed column between two snapshots.
    ///
    /// Pure, and separate from anything that posts a notification, so the rule
    /// can be tested without a notification centre — which cannot even be
    /// constructed outside an app bundle.
    ///
    /// - Parameter ignoring: cards this device moved itself. Telling someone
    ///   about the drag they just performed is noise, and noise is how a user
    ///   learns to swipe your notifications away unread.
    public func moves(
        since previous: BoardSnapshot,
        ignoring: Set<String> = [],
        origin: CardMoveNotice.Origin
    ) -> [CardMoveNotice] {
        var was: [String: String] = [:]
        for column in previous.columns {
            for card in column.cards { was[card.id] = column.name }
        }

        var notices: [CardMoveNotice] = []
        for column in columns {
            for card in column.cards {
                // A card the previous snapshot never had is new, not moved.
                // "Added to To Do" is a different event and not one anybody
                // asked to be told about.
                guard let from = was[card.id], from != column.name else { continue }
                guard !ignoring.contains(card.id) else { continue }
                notices.append(CardMoveNotice(
                    cardTitle: card.title,
                    fromColumn: from,
                    toColumn: column.name,
                    projectName: project.name,
                    origin: origin
                ))
            }
        }
        return notices
    }
}
