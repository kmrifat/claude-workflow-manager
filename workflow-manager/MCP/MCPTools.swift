//
//  MCPTools.swift
//  workflow-manager
//
//  What an agent can do to the boards over MCP, and the rules it is held to.
//
//  The vocabulary follows the field ownership `tasks.json` already settled:
//  an agent reports what only it can know — status, branch, PR — and checks off
//  subtasks and leaves notes. It cannot rename a card, rewrite its details,
//  change its priority, send itself work, or delete anything. There is no tool
//  for any of those, which is a stronger guarantee than a tool that refuses.
//
//  Rules are enforced here, on the Mac, never trusted to the client: a blocked
//  card cannot be claimed, a status needs a column that carries it, and every
//  change is saved with undo disabled — ⌘Z must not undo an agent's work
//  behind its back (see `WorkflowSyncModel.apply`).
//

import Foundation
import SwiftData
import ClaudeWMWire

struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct MCPToolDefinition {
    let name: String
    let title: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let readOnly: Bool

    var json: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": [
                "title": title,
                "readOnlyHint": readOnly,
                "destructiveHint": false,
                "idempotentHint": readOnly,
                "openWorldHint": false,
            ] as [String: Any],
        ]
    }
}

@MainActor
final class MCPTools {
    var context: ModelContext?
    /// The sync coordinator's "this board changed", as `BoardService` has.
    var didMutate: ((Project) -> Void)?

    // MARK: - Definitions

    private static let projectArgument: [String: Any] = [
        "type": "string",
        "description": "Project id, name, or a path inside its repository (your working directory works).",
    ]
    private static let cardArgument: [String: Any] = [
        "type": "string",
        "description": "Card id, as returned by list_cards.",
    ]
    private static let statusValues = WorkflowTasksFile.Status.allCases.map(\.rawValue)

    static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_projects",
            title: "List projects",
            description: "Every project on this Mac's Pitwall board, with its repository path and card counts. Call this first to find the project for your working directory.",
            properties: [
                "include_archived": ["type": "boolean", "description": "Include archived projects. Default false."],
            ],
            required: [],
            readOnly: true
        ),
        MCPToolDefinition(
            name: "list_cards",
            title: "List cards",
            description: "Cards on a project's board. Cards with requested=true are work the user has assigned to you; pick from those first.",
            properties: [
                "project": projectArgument,
                "status": ["type": "string", "enum": statusValues, "description": "Only cards with this status."],
                "requested_only": ["type": "boolean", "description": "Only cards the user sent to Claude. Default false."],
                "include_done": ["type": "boolean", "description": "Include done cards. Default false."],
            ],
            required: ["project"],
            readOnly: true
        ),
        MCPToolDefinition(
            name: "get_card",
            title: "Get card",
            description: "One card in full: details, subtasks with their ids, blockers, linked GitHub issue and recent activity.",
            properties: ["card_id": cardArgument],
            required: ["card_id"],
            readOnly: true
        ),
        MCPToolDefinition(
            name: "claim_card",
            title: "Claim card",
            description: "Start work on a card: marks it as yours and moves it to in_progress, so the user sees you on it. Fails if the card is blocked by unfinished cards.",
            properties: ["card_id": cardArgument],
            required: ["card_id"],
            readOnly: false
        ),
        MCPToolDefinition(
            name: "update_card",
            title: "Update card",
            description: "Report progress: move the card to a status, and record the branch and pull request you made. Set status to review when you open a PR. You cannot change the title, details or priority — those are the user's.",
            properties: [
                "card_id": cardArgument,
                "status": ["type": "string", "enum": statusValues],
                "branch": ["type": "string", "description": "The git branch you are working on."],
                "pr_url": ["type": "string", "description": "The pull request URL, once opened."],
            ],
            required: ["card_id"],
            readOnly: false
        ),
        MCPToolDefinition(
            name: "set_subtask",
            title: "Check off subtask",
            description: "Mark one of a card's subtasks done or not done. Subtask ids come from get_card.",
            properties: [
                "card_id": cardArgument,
                "subtask_id": ["type": "string"],
                "done": ["type": "boolean", "description": "Default true."],
            ],
            required: ["card_id", "subtask_id"],
            readOnly: false
        ),
        MCPToolDefinition(
            name: "add_note",
            title: "Add note",
            description: "Leave a note on a card's activity for the user — a question, a decision, or what is left to do.",
            properties: [
                "card_id": cardArgument,
                "text": ["type": "string"],
            ],
            required: ["card_id", "text"],
            readOnly: false
        ),
    ]

    /// Sent in `initialize`; clients show it to the model as the server's
    /// standing instructions.
    static let instructions = """
    Pitwall is the user's kanban board. Use it to find assigned work and to report progress.

    1. Call list_projects and find the project whose repository contains your working directory.
    2. Call list_cards with requested_only=true for work the user assigned to you.
    3. Before starting a card, call claim_card. Then work.
    4. Record your branch with update_card. When you open a pull request, call update_card with status "review" and pr_url.
    5. Use set_subtask as you finish subtasks, and add_note for anything the user should read.
    6. The user can leave you notes on a card; get_card returns them in its activity, by "You". Read them before you start and when you resume.

    Never move a card to "done" yourself unless the user asked; review is where your work stops.
    """

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: Any], client: String) throws -> [String: Any] {
        guard let context else { throw MCPToolError("The board is not open yet. Try again in a moment.") }
        switch name {
        case "list_projects": return listProjects(arguments, context: context)
        case "list_cards":    return try listCards(arguments, context: context)
        case "get_card":      return try getCard(arguments, context: context)
        case "claim_card":    return try claimCard(arguments, client: client, context: context)
        case "update_card":   return try updateCard(arguments, client: client, context: context)
        case "set_subtask":   return try setSubtask(arguments, client: client, context: context)
        case "add_note":      return try addNote(arguments, client: client, context: context)
        default:              throw MCPToolError("Unknown tool “\(name)”.")
        }
    }

    // MARK: - Reads

    private func listProjects(_ arguments: [String: Any], context: ModelContext) -> [String: Any] {
        let includeArchived = arguments["include_archived"] as? Bool ?? false
        let projects = allProjects(context).filter { includeArchived || $0.status != .archived }
        return ["projects": projects.map { project in
            var entry: [String: Any] = [
                "id": project.uuid.uuidString,
                "name": project.name,
                "status": project.status.rawValue,
                "open_cards": project.openCount,
                "requested_cards": project.allItems.count { $0.workflowRequested && !$0.isDone },
                "in_progress_cards": project.inProgressCount,
                "columns": project.orderedColumns.map { column in
                    ["name": column.name, "status": project.status(for: column).rawValue]
                },
            ]
            if let path = project.repoPath { entry["repository_path"] = path }
            if let slug = project.repoSlug { entry["github"] = slug }
            if let folder = project.folder {
                entry["location"] = folder.path.map(\.displayName).joined(separator: " / ")
            }
            return entry
        }]
    }

    private func listCards(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let project = try resolveProject(arguments["project"], context: context)
        let status = try (arguments["status"] as? String).map(parseStatus)
        let requestedOnly = arguments["requested_only"] as? Bool ?? false
        let includeDone = arguments["include_done"] as? Bool ?? (status == .done)

        let cards = project.allItems.filter { item in
            if requestedOnly, !item.workflowRequested { return false }
            if let status, item.boardStatus != status { return false }
            if !includeDone, item.boardStatus == .done { return false }
            return true
        }
        return [
            "project": ["id": project.uuid.uuidString, "name": project.name],
            "cards": cards.map(summary),
        ]
    }

    private func getCard(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        var card = summary(item)
        card["details"] = item.details
        card["subtasks"] = item.orderedSubtasks.map {
            ["id": $0.uuid.uuidString, "title": $0.title, "done": $0.isDone] as [String: Any]
        }
        card["blocked_by"] = item.openBlockers.map {
            ["id": $0.uuid.uuidString, "title": $0.title, "status": $0.boardStatus?.rawValue ?? "todo"]
        }
        if let project = item.project {
            card["project"] = ["id": project.uuid.uuidString, "name": project.name]
        }
        card["activity"] = item.events
            .filter { !$0.isDeleted }
            .sorted { $0.date > $1.date }
            .prefix(20)
            .map { event in
                var entry: [String: Any] = [
                    "date": Self.iso8601(event.date),
                    "by": event.actor,
                    "summary": event.summary,
                ]
                if let note = event.note { entry["note"] = note }
                return entry
            }
        return ["card": card]
    }

    private func summary(_ item: WorkItem) -> [String: Any] {
        var card: [String: Any] = [
            "id": item.uuid.uuidString,
            "title": item.title,
            "status": item.boardStatus?.rawValue ?? "todo",
            "column": item.column?.name ?? "",
            "priority": item.priority.title.lowercased(),
            "requested": item.workflowRequested,
            "blocked": item.isBlocked,
        ]
        if let number = item.githubIssueNumber { card["github_issue"] = number }
        if let branch = item.workflowBranch { card["branch"] = branch }
        if let pr = item.workflowPRURL { card["pr_url"] = pr }
        if let name = item.agentName, item.agentClaimedAt != nil { card["claimed_by"] = name }
        if let due = item.dueDate { card["due"] = Self.iso8601(due) }
        if !item.tags.isEmpty { card["tags"] = item.tags }
        if item.subtaskCount > 0 { card["subtasks"] = "\(item.completedSubtaskCount)/\(item.subtaskCount)" }
        return card
    }

    // MARK: - Writes

    private func claimCard(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        guard let project = item.project else { throw MCPToolError("That card is not on a board.") }
        if item.isBlocked {
            let names = item.openBlockers.map { "“\($0.title)”" }.formatted(.list(type: .and))
            throw MCPToolError("This card is blocked by \(names). Finish or ask about those first.")
        }
        if item.boardStatus == .done {
            throw MCPToolError("This card is already done.")
        }
        try requireColumn(for: .inProgress, in: project)

        try mutate(project, context: context) {
            item.agentClaimedAt = .now
            item.agentName = client
            record(item, client: client, tool: "claim_card", summary: "Claimed the card", context: context)
            if item.boardStatus != .inProgress {
                try move(item, to: .inProgress, in: project, client: client, tool: "claim_card", context: context)
            }
        }
        return ["card": summary(item)]
    }

    private func updateCard(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        guard let project = item.project else { throw MCPToolError("That card is not on a board.") }
        let status = try (arguments["status"] as? String).map(parseStatus)
        let branch = (arguments["branch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prURL = (arguments["pr_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status != nil || branch != nil || prURL != nil else {
            throw MCPToolError("Nothing to update. Pass status, branch or pr_url.")
        }
        if let prURL, !prURL.isEmpty {
            guard let url = URL(string: prURL), url.scheme == "https" || url.scheme == "http" else {
                throw MCPToolError("pr_url must be an http(s) URL.")
            }
        }
        if status == .inProgress, item.isBlocked {
            throw MCPToolError("This card is blocked by unfinished cards and cannot be started.")
        }
        if let status { try requireColumn(for: ColumnRole(status: status), in: project) }

        try mutate(project, context: context) {
            if let branch, branch != item.workflowBranch {
                item.workflowBranch = branch.isEmpty ? nil : branch
                record(item, client: client, tool: "update_card",
                       summary: branch.isEmpty ? "Cleared the branch" : "Set branch \(branch)", context: context)
            }
            if let prURL, prURL != item.workflowPRURL {
                item.workflowPRURL = prURL.isEmpty ? nil : prURL
                let label = item.pullRequestNumber.map { "PR #\($0)" } ?? "a pull request"
                record(item, client: client, tool: "update_card",
                       summary: prURL.isEmpty ? "Removed the pull request" : "Opened \(label)", context: context)
            }
            if let status, status != item.boardStatus {
                try move(item, to: ColumnRole(status: status), in: project, client: client,
                         tool: "update_card", context: context)
            }
        }
        return ["card": summary(item)]
    }

    private func setSubtask(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        guard let project = item.project else { throw MCPToolError("That card is not on a board.") }
        guard let raw = arguments["subtask_id"] as? String,
              let subtask = item.orderedSubtasks.first(where: { $0.uuid.uuidString.caseInsensitiveCompare(raw) == .orderedSame })
        else {
            throw MCPToolError("No subtask with that id on this card. get_card lists them.")
        }
        let done = arguments["done"] as? Bool ?? true
        if subtask.isDone != done {
            try mutate(project, context: context) {
                subtask.isDone = done
                record(item, client: client, tool: "set_subtask",
                       summary: done ? "Checked off “\(subtask.title)”" : "Unchecked “\(subtask.title)”",
                       context: context)
            }
        }
        return ["card": summary(item)]
    }

    private func addNote(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        guard let project = item.project else { throw MCPToolError("That card is not on a board.") }
        let text = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MCPToolError("The note is empty.") }
        guard text.count <= 10_000 else { throw MCPToolError("Keep notes under 10,000 characters.") }
        try mutate(project, context: context) {
            record(item, client: client, tool: "add_note", summary: "Added a note", note: text, context: context)
        }
        return ["ok": true]
    }

    // MARK: - Mutation plumbing

    /// Applies `body` and saves, both inside an undo-disabled window. SwiftData
    /// registers undo when the context *saves*, so the save has to be inside
    /// too — see `IssueCache.withoutUndo`.
    private func mutate(_ project: Project, context: ModelContext, _ body: () throws -> Void) throws {
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        // No rollback on failure: `rollback()` discards *every* unsaved change
        // in the shared context, including the user's own. The tools validate
        // before they mutate, so a throw here is unexpected; whatever it left
        // half-done is still saved inside the window, so it cannot become an
        // undo step later.
        defer {
            try? context.save()
            undoManager?.enableUndoRegistration()
        }
        try body()
        didMutate?(project)
    }

    /// A board with no column for a status says so: a status that silently
    /// goes nowhere is indistinguishable from the agent being ignored.
    @discardableResult
    private func requireColumn(for role: ColumnRole, in project: Project) throws -> BoardColumn {
        guard let column = project.column(for: role) else {
            throw MCPToolError(
                "No column on “\(project.name)” carries the \(role.status.rawValue) status. Ask the user to set a column’s Claude Status."
            )
        }
        return column
    }

    /// Moves `item` to the column carrying `role`, which callers have already
    /// checked exists.
    private func move(
        _ item: WorkItem,
        to role: ColumnRole,
        in project: Project,
        client: String,
        tool: String,
        context: ModelContext
    ) throws {
        let column = try requireColumn(for: role, in: project)
        let from = item.column
        guard from?.uuid != column.uuid else { return }
        BoardMutations.append(item, to: column)
        record(item, client: client, tool: tool, summary: "Moved to \(column.name)", context: context)
        BoardNotifier.shared.post(CardMoveNotice(
            cardTitle: item.title,
            fromColumn: from?.name,
            toColumn: column.name,
            projectName: project.name,
            origin: .claude
        ))
    }

    private func record(
        _ item: WorkItem,
        client: String,
        tool: String,
        summary: String,
        note: String? = nil,
        context: ModelContext
    ) {
        let event = CardEvent(actor: client, tool: tool, summary: summary, note: note)
        context.insert(event)
        event.item = item
    }

    // MARK: - Lookup

    private func allProjects(_ context: ModelContext) -> [Project] {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.sortOrder)])
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDeleted }
    }

    /// By id, by name, or by a path at or inside the project's repository — an
    /// agent knows its working directory long before it knows any id.
    private func resolveProject(_ value: Any?, context: ModelContext) throws -> Project {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw MCPToolError("Pass a project: its id, name, or a path inside its repository.")
        }
        let projects = allProjects(context)
        if let id = UUID(uuidString: raw), let project = projects.first(where: { $0.uuid == id }) {
            return project
        }
        let named = projects.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw MCPToolError("More than one project is called “\(raw)”. Use its id from list_projects.")
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let path = Self.normalizedPath(raw)
            // Deepest repository wins, so a project nested inside another's
            // folder is not swallowed by the outer one.
            let matches = projects.compactMap { project -> (Project, Int)? in
                guard let repo = project.repoPath.map(Self.normalizedPath) else { return nil }
                return path == repo || path.hasPrefix(repo + "/") ? (project, repo.count) : nil
            }
            if let best = matches.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        throw MCPToolError("No project matches “\(raw)”. list_projects shows them all.")
    }

    private func resolveCard(_ value: Any?, context: ModelContext) throws -> WorkItem {
        guard let raw = value as? String, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw MCPToolError("Pass card_id as the id list_cards returned.")
        }
        guard let item = WorkItem.fetch(id, in: context), !item.isDeleted, item.column != nil else {
            throw MCPToolError("No card with that id. It may have been deleted.")
        }
        return item
    }

    private func parseStatus(_ raw: String) throws -> WorkflowTasksFile.Status {
        guard let status = WorkflowTasksFile.Status(rawValue: raw) else {
            throw MCPToolError("Unknown status “\(raw)”. Use one of: \(Self.statusValues.joined(separator: ", ")).")
        }
        return status
    }

    /// Without a trailing slash, and with `~` expanded. The trailing slash
    /// matters: `standardizedFileURL` keeps one for directories, which would
    /// make every "inside" check fail (see CLAUDE.md, Files).
    private static func normalizedPath(_ raw: String) -> String {
        var path = (raw as NSString).expandingTildeInPath
        path = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
