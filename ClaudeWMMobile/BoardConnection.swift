//
//  BoardConnection.swift
//  ClaudeWMMobile
//
//  The phone's half of the board protocol.
//
//  ## Replies are not request/response
//
//  A mutation produces an `ack` *and* a broadcast `event`, and events for
//  someone else's edit arrive whenever they happen. Reading "the next message"
//  as "the reply" is wrong from the first mutation onward, quietly, because both
//  are valid frames. Everything here is correlated on `MutationRequest.id` or
//  matched by case — never by arrival order.
//
//  ## Reconnecting is the normal case, not the error case
//
//  A phone locks, loses Wi-Fi, and comes back. The Mac sleeps. Neither is
//  exceptional, so a dropped connection sets `.disconnected` and schedules a
//  retry rather than surfacing an error the user has to dismiss.
//

import Foundation
import Network
import Observation
import ClaudeWMWire

@MainActor
@Observable
final class BoardConnection {
    enum State: Equatable {
        case idle
        case connecting
        case connected(serverName: String)
        case disconnected(reason: String)

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    private(set) var state: State = .idle
    private(set) var projects: [WireProjectRef] = []
    private(set) var snapshot: BoardSnapshot?
    /// Set when the Mac refuses something. Cleared when the user acknowledges it
    /// or the next mutation succeeds.
    private(set) var lastFailure: String?

    /// True while a local edit has not yet been confirmed. The board is still
    /// usable; the indicator exists so a user does not assume a stalled edit
    /// landed.
    var hasPendingEdits: Bool { !inFlight.isEmpty }

    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var key: Data?
    private var selectedProjectID: String?

    /// Mutations sent and not yet acked, by request id.
    private var inFlight: [String: BoardMutation] = [:]

    /// Cards this phone moved. Used once, when the next snapshot arrives, to
    /// stay quiet about a move the user just made with their own thumb.
    private var ownMoves: Set<String> = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    private let queue = DispatchQueue(label: "com.binarycastle.claude-wm-mobile.board")

    // MARK: - Connecting

    func connect(to endpoint: NWEndpoint, key: Data) {
        disconnect()
        self.endpoint = endpoint
        self.key = key
        openConnection()
    }

    private func openConnection() {
        guard let endpoint, let key else { return }
        state = .connecting

        let connection = NWConnection(to: endpoint, using: BoardTransport.parameters(key: key))
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.connectionStateChanged(newState) }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func connectionStateChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            reconnectAttempt = 0
            send(.hello(
                token: BoardPairingCode.helloToken(for: key ?? Data()),
                clientName: DeviceName.current
            ))
        case .failed(let error):
            // A wrong key fails here, in the TLS handshake, with `bad MAC`.
            // Worth naming, because "connection failed" sends people to check
            // their Wi-Fi when the answer is to pair again.
            let reason = "\(error)".contains("-9820")
                ? "This phone is no longer paired with that Mac. Scan a new code."
                : error.localizedDescription
            dropped(reason: reason)
        case .cancelled:
            break
        case .waiting(let error):
            state = .connecting
            _ = error
        default:
            break
        }
    }

    private func dropped(reason: String) {
        connection?.cancel()
        connection = nil
        state = .disconnected(reason: reason)
        scheduleReconnect()
    }

    /// Backs off to 30s. A phone in a pocket, away from the Mac's network,
    /// should not spend its battery retrying every second.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        guard endpoint != nil, key != nil else { return }
        let attempt = min(reconnectAttempt, 5)
        reconnectAttempt += 1
        let delay = min(30, pow(2.0, Double(attempt)))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openConnection()
        }
    }

    /// Called when the app returns to the foreground. iOS tears sockets down in
    /// the background, so coming back always means reconnecting — waiting out a
    /// backoff the user cannot see would look like the app is broken.
    func reconnectNow() {
        guard !state.isConnected else {
            // Still nominally connected: make sure the board is not stale.
            if let selectedProjectID { requestSnapshot(projectID: selectedProjectID) }
            return
        }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        openConnection()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        state = .idle
        inFlight.removeAll()
    }

    // MARK: - Reading

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor in self.dropped(reason: "The connection to your Mac was lost.") }
                return
            }
            // End of stream. This is *not* an error and there is no close frame:
            // the peer's socket simply went away — the Mac slept, the app was
            // force-quit, the process died. Re-arming the receive here (which is
            // what ignoring this case does) leaves the phone showing a healthy
            // board forever, with no hint that nothing behind it is live.
            //
            // Missed by the loopback harness because `server.stop()` cancels
            // connections, which surfaces as an error. Only killing the process
            // produces a bare FIN, and only running it on a simulator found it.
            if data == nil, error == nil, isComplete {
                Task { @MainActor in self.dropped(reason: "Your Mac went away.") }
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                Task { @MainActor in self.dropped(reason: "Your Mac closed the connection.") }
                return
            }
            if let data, !data.isEmpty {
                // Decoded off the main actor; only the value crosses over.
                let decoded = try? WireCodec.decodeServerFrame(data)
                if let decoded {
                    Task { @MainActor in self.handle(decoded) }
                }
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ frame: ServerFrame) {
        guard !frame.isFromNewerPeer else {
            dropped(reason: "That Mac is running a newer Claude WM. Update this app.")
            return
        }

        switch frame.message {
        case .welcome(let serverName):
            state = .connected(serverName: serverName)
            // Sets the delegate and asks for permission now that there is a Mac
            // on the other end — see `PhoneNotifier.prepare()`.
            PhoneNotifier.shared.prepare()
            sendPushTokenIfAvailable()
            send(.listProjects)
            if let selectedProjectID { requestSnapshot(projectID: selectedProjectID) }

        case .projects(let projects):
            self.projects = projects
            // Nothing chosen yet and only one board: choosing it for the user
            // is obviously right and saves a pointless tap.
            if selectedProjectID == nil, projects.count == 1 {
                select(projectID: projects[0].id)
            }

        case .snapshot(let incoming):
            guard incoming.project.id == selectedProjectID else { return }
            let previous = snapshot
            self.snapshot = incoming
            // Anything still in flight is now either reflected here or lost;
            // either way the server's board is the truth.
            inFlight.removeAll()
            let mine = ownMoves
            ownMoves.removeAll()
            if let previous { announceMoves(from: previous, to: incoming, ignoring: mine) }

        case .event(let projectID, let revision):
            guard projectID == selectedProjectID else { return }
            // Only ask for a board if ours is actually out of date. This is what
            // keeps an idle phone at one integer per change.
            if snapshot?.revision != revision {
                requestSnapshot(projectID: projectID)
            }

        case .ack(let requestID, _):
            inFlight[requestID] = nil
            lastFailure = nil

        case .failure(let failure):
            if let requestID = failure.requestID, inFlight[requestID] != nil {
                inFlight[requestID] = nil
                // The optimistic edit was wrong. Rather than inverting it, ask
                // for the truth — inverting a move means remembering where it
                // came from, and being wrong about that is worse than a flicker.
                //
                // `force` matters and its absence was a real bug: a *refused*
                // mutation leaves the server's board unchanged, so a normal
                // request carrying our revision is answered with "you are up to
                // date" — and the phone keeps showing the edit that was
                // rejected, permanently. The revision optimisation assumes our
                // copy is right, which is exactly what a rejection disproves.
                if let selectedProjectID {
                    requestSnapshot(projectID: selectedProjectID, force: true)
                }
            }
            lastFailure = failure.message

        case .unrecognized:
            break
        }
    }

    // MARK: - Writing

    /// Hands the Mac this phone's APNs token, so it can be reached while
    /// asleep. Sent after `hello` on purpose: the Mac must not accept a push
    /// target from a peer that has not proved the pairing key.
    ///
    /// The token often is not ready at connect time — Apple answers
    /// asynchronously — so this is also called when it arrives.
    func sendPushTokenIfAvailable() {
        guard state.isConnected, let token = PushRegistration.shared.token else { return }
        send(.registerPush(deviceID: PushRegistration.shared.deviceID, token: token))
    }

    func select(projectID: String) {
        selectedProjectID = projectID
        snapshot = nil
        requestSnapshot(projectID: projectID)
    }

    /// - Parameter force: ask for the whole board even if our revision looks
    ///   current. Needed after a rejected edit, when the board we are showing is
    ///   known to be wrong and the server's is unchanged.
    func requestSnapshot(projectID: String, force: Bool = false) {
        send(.requestSnapshot(projectID: projectID, haveRevision: force ? nil : snapshot?.revision))
    }

    func dismissFailure() { lastFailure = nil }

    private func send(_ message: ClientMessage) {
        guard let connection, let data = try? WireCodec.encode(ClientFrame(message: message)) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        connection.send(
            content: data,
            contentContext: .init(identifier: "frame", metadata: [metadata]),
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    // MARK: - Mutating

    /// Applies the edit locally, then sends it.
    ///
    /// Optimistic on purpose: a Wi-Fi round trip is long enough that waiting for
    /// it makes a drag feel broken. The server's next snapshot is authoritative
    /// and will correct anything the phone got wrong.
    func mutate(_ mutation: BoardMutation) {
        guard let projectID = selectedProjectID else { return }
        let requestID = UUID().uuidString
        inFlight[requestID] = mutation
        if case .moveCard(let cardID, _, _) = mutation { ownMoves.insert(cardID) }
        applyLocally(mutation)
        send(.mutate(MutationRequest(id: requestID, projectID: projectID, mutation: mutation)))
    }

    /// Announces moves the phone did not make itself.
    ///
    /// The phone cannot know *who* moved a card — the wire carries a board, not
    /// an audit log — only that one moved and that it was not us. The rule
    /// itself lives in `BoardSnapshot.moves(since:ignoring:origin:)` so it can
    /// be tested away from a notification centre.
    private func announceMoves(
        from previous: BoardSnapshot,
        to current: BoardSnapshot,
        ignoring mine: Set<String>
    ) {
        // The Mac is the only peer this phone talks to, so a move it did not
        // make arrived from over there, whoever originally caused it.
        for notice in current.moves(since: previous, ignoring: mine, origin: .mac) {
            PhoneNotifier.shared.post(notice)
        }
    }

    /// The phone's guess at what the Mac will do. Only the cases a finger can
    /// reach are modelled; anything else simply waits for the snapshot.
    private func applyLocally(_ mutation: BoardMutation) {
        guard var snapshot else { return }
        defer { self.snapshot = snapshot }

        switch mutation {
        case .setTitle(let cardID, let title):
            edit(cardID, in: &snapshot) { $0.title = title }
        case .setDetails(let cardID, let details):
            edit(cardID, in: &snapshot) { $0.details = details }
        case .setPriority(let cardID, let priority):
            edit(cardID, in: &snapshot) { $0.priority = priority }
        case .setRequested(let cardID, let requested):
            edit(cardID, in: &snapshot) { $0.requested = requested }
        case .deleteCard(let cardID):
            for index in snapshot.columns.indices {
                snapshot.columns[index].cards.removeAll { $0.id == cardID }
            }
        case .moveCard(let cardID, let toColumnID, let index):
            var moved: WireCard?
            for columnIndex in snapshot.columns.indices {
                if let found = snapshot.columns[columnIndex].cards.firstIndex(where: { $0.id == cardID }) {
                    moved = snapshot.columns[columnIndex].cards.remove(at: found)
                    break
                }
            }
            guard let moved,
                  let target = snapshot.columns.firstIndex(where: { $0.id == toColumnID })
            else { return }
            let clamped = min(max(index, 0), snapshot.columns[target].cards.count)
            snapshot.columns[target].cards.insert(moved, at: clamped)
        case .createCard, .unrecognized:
            // The Mac mints card ids, so there is nothing sensible to draw until
            // it answers. Guessing one would produce a card that vanishes and
            // reappears with a different identity.
            break
        }
    }

    private func edit(
        _ cardID: String,
        in snapshot: inout BoardSnapshot,
        _ change: (inout WireCard) -> Void
    ) {
        for columnIndex in snapshot.columns.indices {
            guard let cardIndex = snapshot.columns[columnIndex].cards
                .firstIndex(where: { $0.id == cardID }) else { continue }
            change(&snapshot.columns[columnIndex].cards[cardIndex])
            return
        }
    }
}
