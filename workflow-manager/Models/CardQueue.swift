//
//  CardQueue.swift
//  workflow-manager
//
//  What the sidebar's smart lists and the Overview count: cards that need
//  attention, gathered across every project.
//
//  All of it is derived from state the board already has, not from the
//  `CardEvent` log — a card is being worked on by Claude when it was sent or
//  claimed and now sits in an in-progress column. That is exactly what the
//  board shows, so the two can never disagree.
//

import Foundation

/// Where a card stands with Claude.
enum AgentState: Equatable, Sendable {
    /// Neither sent to Claude nor claimed by an agent.
    case none
    /// Sent, not yet picked up.
    case queued
    case working
    /// The agent moved it to review — usually with a PR.
    case inReview
    case done
}

extension WorkItem {
    /// The sync status this card's column reports, whether or not the project
    /// is syncing. `nil` only for a card detached from any column.
    ///
    /// A completion column is `done` whatever it inherits: a Done column with
    /// no Claude status of its own sits right of Review and would otherwise
    /// report every finished card as waiting for review.
    var boardStatus: WorkflowTasksFile.Status? {
        guard let column, let project = column.project else { return nil }
        if column.isCompletionColumn { return .done }
        return project.status(for: column)
    }

    /// A card is with Claude once it was sent (`workflowRequested`) or an
    /// agent claimed it over MCP (`agentClaimedAt`); its column then says how
    /// far the agent got. A sent card still in a to-do column is queued; a
    /// claimed one that a person dragged back to to-do is no longer Claude's.
    var agentState: AgentState {
        guard workflowRequested || agentClaimedAt != nil, let boardStatus else { return .none }
        switch boardStatus {
        case .todo:       return workflowRequested ? .queued : .none
        case .inProgress: return .working
        case .review:     return .inReview
        case .done:       return .done
        }
    }

    /// The number at the end of `workflowPRURL`, e.g. 212 for
    /// `https://github.com/o/r/pull/212`.
    var pullRequestNumber: Int? {
        guard let url = workflowPRURL else { return nil }
        let last = url.split(separator: "/").last.map(String.init) ?? ""
        return Int(last)
    }
}

/// A cross-project list in the sidebar.
enum CardQueue: String, CaseIterable, Identifiable, Sendable {
    case agents
    case review
    case overdue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents:  "Agents Working"
        case .review:  "Needs Review"
        case .overdue: "Overdue"
        }
    }

    var symbol: String {
        switch self {
        case .agents:  "sparkles"
        case .review:  "arrow.triangle.pull"
        case .overdue: "clock.badge.exclamationmark"
        }
    }

    var emptyMessage: String {
        switch self {
        case .agents:  "No card is with Claude right now. Send one from its menu."
        case .review:  "Nothing is waiting in a review column."
        case .overdue: "Every card with a due date is on time."
        }
    }

    func includes(_ item: WorkItem) -> Bool {
        switch self {
        case .agents:  item.agentState == .working
        case .review:  item.boardStatus == .review
        case .overdue: item.isOverdue
        }
    }

    /// Matching cards, grouped by project in project order. Archived projects
    /// are left out: an overdue card in a shelved project is not a to-do.
    func items(in projects: [Project]) -> [(project: Project, items: [WorkItem])] {
        projects
            .filter { $0.status != .archived }
            .compactMap { project in
                let matches = project.allItems.filter(includes)
                return matches.isEmpty ? nil : (project, matches)
            }
    }

    func count(in projects: [Project]) -> Int {
        items(in: projects).reduce(0) { $0 + $1.items.count }
    }
}
