//
//  MCPTools.swift
//  workflow-manager
//
//  What an agent can do to the boards over MCP, and the rules it is held to.
//
//  The vocabulary follows the field ownership `tasks.json` already settled:
//  an agent reports what only it can know — status, branch, PR — and checks off
//  subtasks and leaves notes. It cannot rename a card, rewrite its details,
//  change its priority or send itself work. There is no tool for any of those,
//  which is a stronger guarantee than a tool that refuses.
//
//  It can *add* a card (`create_card`) — follow-up work it found, or a big card
//  split up — and that tool is additive in the way filing a GitHub issue from a
//  card is: it touches nothing that already exists, the card lands in To Do
//  never sent to Claude (an agent cannot hand itself work), and its activity
//  says who made it. A cap per hour keeps a looping agent from burying a board.
//
//  It can delete a card (`delete_card`), any card — the owner's choice. A
//  deleted card takes its activity with it, so the trace has to live outside
//  it: a reason is required, and the Mac posts a notification naming the card
//  and the reason. Its own hourly cap stops a runaway clean-up.
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
    /// Told to the client, which may ask the user before calling it.
    var destructive = false

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
                "destructiveHint": destructive,
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
            description: "One card in full: details, subtasks with their ids, blockers, linked GitHub issue and recent activity — plus the images pasted into its details, as images you can see.",
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
            name: "create_card",
            title: "Create card",
            description: "Add a new card to a project's board — follow-up work you found, or a large card split into smaller ones. It lands in To Do and is not sent to you: the user decides whether and when it is worked on. Pass from_card_id when it comes out of a card you are working on, so both cards say so.",
            properties: [
                "project": projectArgument,
                "title": ["type": "string", "description": "Short, like a commit subject."],
                "details": ["type": "string", "description": "Markdown: what and why, and what done looks like."],
                "subtasks": ["type": "array", "items": ["type": "string"], "description": "Optional checklist, in order."],
                "from_card_id": ["type": "string", "description": "The card this came out of, if any."],
            ],
            required: ["project", "title"],
            readOnly: false
        ),
        MCPToolDefinition(
            name: "delete_card",
            title: "Delete card",
            description: "Delete a card from its board, with its subtasks, notes and images. This cannot be undone. Only do it when the user asked you to, or to remove a card you created by mistake. The user is notified, with your reason.",
            properties: [
                "card_id": cardArgument,
                "reason": ["type": "string", "description": "Why, in a sentence. Shown to the user."],
            ],
            required: ["card_id", "reason"],
            readOnly: false,
            destructive: true
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

    static func offers(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    /// Sent in `initialize`; clients show it to the model as the server's
    /// standing instructions.
    static let instructions = """
    Pitwall is the user's kanban board. Use it to find assigned work and to report progress.

    1. Call list_projects and find the project whose repository contains your working directory.
    2. Call list_cards with requested_only=true for work the user assigned to you.
    3. Before starting a card, call claim_card. Then work.
    4. Record your branch with update_card. When you open a pull request, call update_card with status "review" and pr_url.
    5. Use set_subtask as you finish subtasks, and add_note for anything the user should read.
    6. Work you find outside the card you are on goes on the board with create_card (pass from_card_id), not into this branch. It waits in To Do for the user. Delete a card only when the user asks, or to undo a card you created by mistake.
    7. The user can leave you notes on a card; get_card returns them in its activity, by "You". Read them before you start and when you resume.
    8. Images in a card's details appear as ![name](attachment:<id>); get_card returns the first few as images you can see.

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
        case "create_card":   return try createCard(arguments, client: client, context: context)
        case "delete_card":   return try deleteCard(arguments, client: client, context: context)
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

        // Images in the notes: listed in the card, and the first few sent as
        // image content so the model can look at them — a pasted screenshot is
        // often the whole bug report. Scaled down: full-size screenshots are
        // megabytes, and a model sees no more detail than this.
        let images = AttachmentReferences.ids(in: item.details).compactMap { id in
            item.attachments.first { $0.uuid == id && !$0.isDeleted }
        }
        var result: [String: Any] = ["card": card]
        if !images.isEmpty {
            card["images"] = images.map {
                ["id": $0.uuid.uuidString, "name": $0.filename, "width": $0.pixelWidth, "height": $0.pixelHeight]
                    as [String: Any]
            }
            result["card"] = card
            result[MCPTools.imagesKey] = images.prefix(Self.maxImages).compactMap { attachment -> [String: String]? in
                guard let jpeg = AttachmentImage.preview(of: attachment.data) else { return nil }
                return ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
            }
        }
        return result
    }

    /// Where a tool hands back images; `MCPServer` turns them into image
    /// content and keeps them out of the JSON text.
    static let imagesKey = "__images"
    static let maxImages = 4

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

    /// Cards an agent may create on one board in an hour. Generous for a
    /// split or a run of follow-ups; a loop hits it long before the board is
    /// unreadable.
    static let createLimitPerHour = 20
    static let maxSubtasks = 30

    private func createCard(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let project = try resolveProject(arguments["project"], context: context)
        let title = (arguments["title"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { throw MCPToolError("A card needs a title.") }
        guard title.count <= 200 else { throw MCPToolError("Keep the title under 200 characters; put the rest in details.") }
        let details = (arguments["details"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard details.count <= 20_000 else { throw MCPToolError("Keep details under 20,000 characters.") }
        if arguments["subtasks"] != nil, !(arguments["subtasks"] is [Any]) {
            throw MCPToolError("subtasks must be a list of strings.")
        }
        let subtasks = (arguments["subtasks"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard subtasks.count <= Self.maxSubtasks else {
            throw MCPToolError("At most \(Self.maxSubtasks) subtasks. Split the work into more than one card.")
        }
        guard subtasks.allSatisfy({ $0.count <= 200 }) else { throw MCPToolError("Keep each subtask under 200 characters.") }

        // The card it came out of must be on this board: a follow-up filed on
        // another project would point at a card the user cannot see from here.
        var source: WorkItem?
        if let raw = arguments["from_card_id"] {
            let card = try resolveCard(raw, context: context)
            guard card.project?.uuid == project.uuid else {
                throw MCPToolError("from_card_id is a card on another project. Create the card there, or leave from_card_id out.")
            }
            source = card
        }

        let hourAgo = Date.now.addingTimeInterval(-3600)
        // Counted from the cards' own "Created by" events — there is no other
        // record, and a deleted card's no longer counts, which is fair.
        let recent = project.allItems.reduce(0) { count, item in
            count + item.events.count {
                !$0.isDeleted && $0.tool == "create_card" && $0.summary.hasPrefix("Created by") && $0.date > hourAgo
            }
        }
        guard recent < Self.createLimitPerHour else {
            throw MCPToolError("""
                \(Self.createLimitPerHour) cards have already been created on “\(project.name)” in the last hour. \
                Put the rest in a note with add_note and let the user decide.
                """)
        }

        // To Do, never a column the agent picks: where work waits for the
        // user. A board with no To Do role gets it in its first column.
        guard let column = project.column(for: .todo) ?? project.orderedColumns.first else {
            throw MCPToolError("“\(project.name)” has no columns to put a card in.")
        }

        var created: WorkItem?
        try mutate(project, context: context) {
            let item = BoardMutations.addItem(titled: title, to: column, in: context)
            item.details = details
            var order = 0.0
            for title in subtasks {
                order = FractionalOrder.afterLast(of: [order])
                let subtask = Subtask(title: title, sortOrder: order)
                context.insert(subtask)
                subtask.item = item
            }
            let origin = source.map { " from “\($0.title)”" } ?? ""
            record(item, client: client, tool: "create_card", summary: "Created by \(client)\(origin)", context: context)
            if let source {
                record(source, client: client, tool: "create_card", summary: "Created follow-up “\(title)”",
                       context: context)
            }
            created = item
        }
        guard let created else { throw MCPToolError("The card could not be created.") }
        var card = summary(created)
        card["project"] = ["id": project.uuid.uuidString, "name": project.name]
        return ["card": card]
    }

    /// Cards an agent may delete on one board in an hour.
    static let deleteLimitPerHour = 20
    /// When each recent deletion happened, by project. In memory: a deleted
    /// card leaves nothing in the store to count, and a relaunch starting the
    /// count again is a fair price.
    private var deletions: [UUID: [Date]] = [:]

    private func deleteCard(_ arguments: [String: Any], client: String, context: ModelContext) throws -> [String: Any] {
        let item = try resolveCard(arguments["card_id"], context: context)
        guard let project = item.project else { throw MCPToolError("That card is not on a board.") }
        let reason = (arguments["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw MCPToolError("Say why in reason — the user is shown it.") }
        guard reason.count <= 500 else { throw MCPToolError("Keep the reason under 500 characters.") }

        let hourAgo = Date.now.addingTimeInterval(-3600)
        let recent = (deletions[project.uuid] ?? []).filter { $0 > hourAgo }
        guard recent.count < Self.deleteLimitPerHour else {
            throw MCPToolError("""
                \(Self.deleteLimitPerHour) cards have already been deleted from “\(project.name)” in the last hour. \
                Ask the user before deleting more.
                """)
        }

        let title = item.title
        try mutate(project, context: context) {
            context.delete(item)
        }
        deletions[project.uuid] = recent + [.now]
        BoardNotifier.shared.postDeletion(cardTitle: title, projectName: project.name, actor: client, reason: reason)
        return ["deleted": ["title": title, "project": project.name]]
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
