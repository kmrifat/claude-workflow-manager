//
//  CardEvent.swift
//  workflow-manager
//
//  One line of a card's activity: who did what, and through which MCP tool.
//
//  Written only when an agent changes a card through the MCP server — the one
//  writer whose changes otherwise just *happen* to the board with nobody
//  watching. A user's own edits are not logged: they saw them happen.
//
//  It is a record, not state. Nothing reads it back to decide anything, and
//  deleting every row loses only history.
//

import Foundation
import SwiftData

@Model
final class CardEvent {
    var uuid: UUID = UUID()
    var date: Date = Date.now
    /// Who acted, as the client named itself — "claude-code 2.1.4", say.
    var actor: String = ""
    /// The MCP tool that made the change, e.g. `update_card`.
    var tool: String?
    /// What happened, in a sentence: "Moved to In Progress".
    var summary: String = ""
    /// Set for `add_note`: the note itself, kept apart from `summary` so a long
    /// note does not have to be a one-line description.
    var note: String?

    /// Inverse is declared on `WorkItem.events`.
    var item: WorkItem?

    init(actor: String, tool: String?, summary: String, note: String? = nil) {
        self.actor = actor
        self.tool = tool
        self.summary = summary
        self.note = note
    }
}
