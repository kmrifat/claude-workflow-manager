//
//  BoardService.swift
//  workflow-manager
//
//  What a phone's message *means*. `BoardServer` owns sockets and frames and
//  knows nothing about boards; this owns the board and knows nothing about
//  sockets beyond a client id to reply to.
//
//  ## Mutations go through `BoardMutations`, always
//
//  Not because it is tidy, but because ordering lives in `FractionalOrder` and
//  completion state is applied on entering a column. A phone that set
//  `item.column` directly would produce cards with colliding sort orders and a
//  card sitting in Done that was never marked done — both of which look like
//  board corruption and neither of which is obviously a networking bug.
//
//  ## Undo
//
//  A phone's edit must not land in the Mac user's ⌘Z stack. SwiftData registers
//  its undo action when the context *saves*, not when an object is mutated, so
//  disabling registration around the mutation alone does nothing — the next
//  autosave registers it after the window has closed. The save has to happen
//  inside the disabled window. `WorkflowSyncModel.apply` and
//  `IssueCache.withoutUndo` do the same dance for the same reason.
//

import Foundation
import SwiftData
import ClaudeWMWire

@MainActor
final class BoardService: BoardServerHandler {
    private let context: ModelContext
    private let expectedToken: () -> Data?

    /// Called after a mutation lands, so the owner can tell the file-sync layer
    /// that the board moved. Card 7's problem, kept as a seam so this file does
    /// not have to know how that works.
    var didMutate: ((Project) -> Void)?

    /// Which phone is on which connection, so a disconnect can mark that device
    /// reachable-by-push again.
    private var deviceIDByClient: [UUID: String] = [:]

    /// Terminal and Files, when the Mac's owner has enabled them. Optional so a
    /// test can build a board-only service, and so the feature is absent rather
    /// than merely refusing if it is ever compiled out.
    private var repository: RepositoryService?

    init(context: ModelContext, expectedToken: @escaping () -> Data? = { BoardPairing.loadKey() }) {
        self.context = context
        self.expectedToken = expectedToken
    }

    /// Gives this service somewhere to send terminal and file messages. Set by
    /// the owner after construction because the terminal store is app-level
    /// state that outlives any one board.
    func attachRepositoryAccess(terminals: TerminalStateStore) {
        repository = RepositoryService(terminals: terminals) { [weak self] id in
            self?.project(id: id)
        }
    }

    // MARK: - Dispatch

    func handle(_ message: ClientMessage, from client: UUID, on server: BoardServer) {
        // Everything except `hello` requires `hello` to have succeeded. TLS
        // already proved the peer holds the key; this is the protocol's own
        // handshake, and skipping it must not be a way in.
        if case .hello = message {} else if !server.isReady(client) {
            server.send(.failure(WireFailure(
                code: .unauthorized,
                message: "Say hello first."
            )), to: client)
            return
        }

        // Terminal and file messages are answered by `RepositoryService`, which
        // has its own switch to turn off. It returns false for anything that is
        // not its business, so the board's own handling below is unchanged.
        if let repository, repository.handle(message, from: client, on: server) { return }

        switch message {
        case .hello(let token, let name):
            handleHello(token: token, name: name, client: client, server: server)

        case .listProjects:
            server.send(.projects(BoardSnapshotBuilder.references(to: allProjects())), to: client)

        case .requestSnapshot(let projectID, let haveRevision):
            guard let project = project(id: projectID) else {
                server.send(.failure(WireFailure(
                    code: .unknownProject,
                    message: "That board is no longer on this Mac."
                )), to: client)
                return
            }
            // Nothing changed: answer with the revision it already has rather
            // than resending a board over Wi-Fi for no reason.
            let revision = BoardSnapshotBuilder.revision(of: project)
            if let haveRevision, haveRevision == revision {
                server.send(.event(projectID: projectID, revision: revision), to: client)
                return
            }
            server.send(.snapshot(BoardSnapshotBuilder.snapshot(of: project)), to: client)

        case .mutate(let request):
            handleMutation(request, client: client, server: server)

        case .registerPush(let deviceID, let token):
            // Arrives after `hello`, so the pairing key has already been proved
            // — a token from an unpaired peer would let anyone aim this Mac's
            // pushes at a device of their choosing.
            deviceIDByClient[client] = deviceID
            PushRegistry.shared.register(deviceID: deviceID, token: token)
            // Connected devices get their own local notifications, so they are
            // excluded from pushes until this socket drops.
            PushRegistry.shared.markConnected(deviceID)

        case .listTerminals, .attachTerminal, .detachTerminal, .terminalInput,
             .terminalAction, .listDirectory, .readFile:
            // Only reached when no `RepositoryService` was attached at all, which
            // is a build without the feature rather than one with it switched
            // off. Both look the same from the phone, and should.
            server.send(.failure(WireFailure(
                code: .forbidden,
                message: "Terminal and file access isn’t available on this Mac."
            )), to: client)

        case .unrecognized(let type):
            server.send(.failure(WireFailure(
                code: .unsupportedMutation,
                message: "This Mac doesn’t understand “\(type)”. Update Claude WM."
            )), to: client)
        }
    }

    private func handleHello(token: String, name: String, client: UUID, server: BoardServer) {
        // Belt and braces. An unpaired peer cannot complete the TLS handshake,
        // so in practice this never fails — but "the transport already checked"
        // is exactly the assumption that stops being true when the transport
        // changes.
        guard let expected = expectedToken(),
              let offered = Data(base64Encoded: token),
              constantTimeEquals(offered, expected)
        else {
            server.send(.failure(WireFailure(
                code: .unauthorized,
                message: "That device isn’t paired with this Mac."
            )), to: client)
            server.disconnect(client)
            return
        }
        server.markReady(client, name: name)
        server.send(.welcome(serverName: BoardServer.defaultServiceName), to: client)
    }

    /// Called by the transport when a connection goes away, so the device
    /// becomes push-eligible again. Without this, a phone that connected once
    /// would never be pushed to — which is precisely the case APNs is for.
    func clientDisconnected(_ client: UUID) {
        repository?.clientDisconnected(client)
        guard let deviceID = deviceIDByClient.removeValue(forKey: client) else { return }
        PushRegistry.shared.markDisconnected(deviceID)
    }

    // MARK: - Mutations

    private func handleMutation(_ request: MutationRequest, client: UUID, server: BoardServer) {
        guard let project = project(id: request.projectID) else {
            fail(request, .unknownProject, "That board is no longer on this Mac.", client, server)
            return
        }

        let outcome = apply(request.mutation, to: project)
        switch outcome {
        case .applied:
            let revision = BoardSnapshotBuilder.revision(of: project)
            server.send(.ack(requestID: request.id, revision: revision), to: client)
            // The `event` that tells every phone is *not* sent from here.
            // `didMutate` reaches the sync coordinator, which is the single
            // publisher of "this board changed" — it also sees edits made on the
            // Mac, and a board that announced itself from two places would send
            // every phone mutation twice.
            didMutate?(project)
        case .rejected(let code, let reason):
            fail(request, code, reason, client, server)
        }
    }

    private enum Outcome {
        case applied
        case rejected(WireFailure.Code, String)
    }

    private func apply(_ mutation: BoardMutation, to project: Project) -> Outcome {
        // The whole mutation, including its save, happens inside the disabled
        // window. See the note at the top of this file — moving the save out
        // silently re-enables undo registration for it.
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            try? context.save()
            undoManager?.enableUndoRegistration()
        }

        switch mutation {
        case .createCard(let columnID, let title, let details):
            guard let column = self.column(id: columnID, in: project) else {
                return .rejected(.unknownCard, "That column is no longer on this board.")
            }
            let item = BoardMutations.addItem(titled: title, to: column, in: context)
            item.details = details
            return .applied

        case .moveCard(let cardID, let columnID, let index):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            guard let column = self.column(id: columnID, in: project) else {
                return .rejected(.unknownCard, "That column is no longer on this board.")
            }
            // `Int.max` is the wire's spelling for "the end" — clamped by
            // `move`, but pinned here so the intent is not accidental.
            let target = index == Int.max ? column.orderedItems.count : index
            let from = item.column
            BoardMutations.move(item, to: column, insertingAt: target)

            // Only a move between columns is worth telling anyone about;
            // reordering within one is not news.
            if from?.uuid != column.uuid {
                BoardNotifier.shared.post(CardMoveNotice(
                    cardTitle: item.title,
                    fromColumn: from?.name,
                    toColumn: column.name,
                    projectName: project.name,
                    origin: .phone
                ))
            }
            return .applied

        case .setTitle(let cardID, let title):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            item.title = title
            return .applied

        case .setDetails(let cardID, let details):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            item.details = details
            return .applied

        case .setPriority(let cardID, let priority):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            item.priorityRaw = modelPriority(for: priority).rawValue
            return .applied

        case .setRequested(let cardID, let requested):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            // The Mac refuses to send a blocked card to an agent, and the phone
            // has to obey the same rule. Enforced here rather than trusting the
            // client: a stale phone may not know a blocker was added a second
            // ago, and a rule only the UI applies is not a rule.
            if requested, item.isBlocked {
                return .rejected(.rejected, "That card is blocked by unfinished work.")
            }
            item.workflowRequested = requested
            return .applied

        case .deleteCard(let cardID):
            guard let item = card(id: cardID, in: project) else {
                return .rejected(.unknownCard, "That card is no longer on this board.")
            }
            context.delete(item)
            return .applied

        case .unrecognized(let kind):
            return .rejected(.unsupportedMutation, "This Mac doesn’t understand “\(kind)”.")
        }
    }

    // MARK: - Lookup
    //
    // Projects come from a fetch and still need filtering; columns and cards go
    // through the ordered accessors, which drop deleted objects themselves. That
    // matters here: a mutation applied to a card deleted a moment ago would
    // succeed, ack, and change nothing anybody can see.

    private func allProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.sortOrder)])
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDeleted }
    }

    private func project(id: String) -> Project? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return allProjects().first { $0.uuid == uuid }
    }

    private func column(id: String, in project: Project) -> BoardColumn? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return project.orderedColumns.first { $0.uuid == uuid }
    }

    private func card(id: String, in project: Project) -> WorkItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return project.allItems.first { $0.uuid == uuid }
    }

    private func modelPriority(for priority: WirePriority) -> Priority {
        switch priority {
        case .low:    .low
        case .normal: .normal
        case .high:   .high
        case .urgent: .urgent
        }
    }

    private func fail(
        _ request: MutationRequest,
        _ code: WireFailure.Code,
        _ message: String,
        _ client: UUID,
        _ server: BoardServer
    ) {
        server.send(.failure(WireFailure(
            requestID: request.id,
            code: code,
            message: message
        )), to: client)
    }
}

/// Length-independent only for equal-length inputs, which is all this compares.
/// Overkill against a peer that already completed a PSK handshake, and cheap
/// enough that arguing about it costs more than keeping it.
private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
    return difference == 0
}
