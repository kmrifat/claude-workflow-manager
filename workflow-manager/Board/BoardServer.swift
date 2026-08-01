//
//  BoardServer.swift
//  workflow-manager
//
//  The listener Claude WM offers to its phone client. Transport only: it knows
//  about sockets, TLS and frames, and nothing about boards. What a message
//  *means* is `BoardService`'s problem.
//
//  ## Why WebSocket only, and no HTTP
//
//  Vapor cannot be a dependency of this target (see CLAUDE.md), so an HTTP
//  server here would have to be hand-written — request parsing, chunked bodies,
//  the upgrade handshake, all of it. `NWProtocolWebSocket` already implements
//  the handshake and the frame layer, so speaking only WebSocket removes that
//  entire surface. There are no paths and no methods because there is no HTTP to
//  have them: every frame names its own type.
//
//  ## Why a pre-shared key rather than a self-signed certificate
//
//  The pairing story was going to be "self-signed cert, pin its fingerprint in
//  the QR code". Generating a self-signed X.509 in-process on macOS has no clean
//  public API — it means hand-assembling DER — and it leaves a certificate to
//  expire, to store, and to get wrong.
//
//  TLS-PSK removes the certificate entirely. The QR code carries a random key,
//  both ends feed it to TLS, and a peer that does not have it cannot complete a
//  handshake — so an unpaired client never reaches any of our code. Trust is the
//  QR code, in one place, rather than split between a token and a fingerprint.
//
//  The cost: PSK ciphersuite plumbing is the finicky corner of Network.framework
//  and cannot be taken on faith. `BoardServerLoopbackTests` in the scratch
//  harness runs a real handshake against a real client for exactly that reason.
//
//  ## Threading
//
//  Network.framework delivers on `queue`, and that is deliberately not the main
//  queue: decoding happens there, and only the decoded value hops to the main
//  actor. The terminal emulator already taught this codebase what parsing on the
//  main thread costs.
//

import Foundation
import Network
import ClaudeWMWire

@MainActor
@Observable
final class BoardServer {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        /// Terminal. The listener is not retrying on its own — a port already in
        /// use or a denied firewall prompt does not fix itself, and a silent
        /// retry loop would hide both.
        case failed(String)

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    /// A connected phone, as much as the transport knows about one.
    struct Client: Identifiable, Equatable {
        let id: UUID
        var name: String
        let connectedAt: Date
        /// Set once `hello` has been accepted. Until then the connection may
        /// send nothing else — TLS proves the key, this proves the protocol.
        var isReady: Bool
    }

    private(set) var state: State = .stopped
    private(set) var clients: [Client] = []

    weak var handler: (any BoardServerHandler)?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.binarycastle.workflow-manager.board-server")

    // MARK: - Lifecycle

    /// Off by default, and started explicitly. A kanban app that opens a
    /// listening socket the first time it launches is not something to do to
    /// someone quietly.
    ///
    /// - Parameter port: 0 asks the kernel for a free one, which is the normal
    ///   case — the phone finds the real port over Bonjour rather than being
    ///   told a constant that may already be taken.
    func start(key: Data, serviceName: String? = nil, port: UInt16 = 0) {
        guard case .stopped = state else { return }
        guard !key.isEmpty else {
            state = .failed("No pairing key. Pair a device first.")
            return
        }
        state = .starting

        let listener: NWListener
        do {
            let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
            listener = try NWListener(using: Self.parameters(key: key), on: endpointPort)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // Advertised so the phone resolves a *name* rather than remembering an
        // address. A pairing that survives one DHCP lease is not a pairing.
        //
        // Bonjour publishes the name and port on the local network, and that is
        // all it publishes — the key is never in a TXT record, and an
        // unauthenticated browser learns only that a Mac is running this app.
        listener.service = NWListener.Service(
            name: serviceName ?? Self.defaultServiceName,
            type: BoardPairing.bonjourType
        )

        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in self?.listenerStateChanged(newState) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        clients.removeAll()
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .running(port: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            // The first `listen` triggers the macOS incoming-connections prompt.
            // A denial arrives here, not as a thrown error from the initialiser.
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        case .cancelled:
            if case .failed = state {} else { state = .stopped }
        default:
            break
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        clients.append(Client(id: id, name: "Connecting…", connectedAt: .now, isReady: false))

        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func drop(_ id: UUID) {
        connections[id]?.cancel()
        connections[id] = nil
        clients.removeAll { $0.id == id }
        handler?.clientDisconnected(id)
    }

    func disconnect(_ id: UUID) { drop(id) }

    /// Marks a client as having completed `hello`. Called by the service once it
    /// has checked the token; the transport does not know what a valid one is.
    func markReady(_ id: UUID, name: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[index].name = name
        clients[index].isReady = true
    }

    func isReady(_ id: UUID) -> Bool {
        clients.first { $0.id == id }?.isReady ?? false
    }

    // MARK: - Reading
    //
    // One message at a time, and the next receive is only armed after the
    // current one is dispatched. WebSocket delivers whole messages, so there is
    // no reassembly to do — but there is also no backpressure if we queue
    // receives ahead of handling.

    private nonisolated func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor in self.drop(id) }
                return
            }
            // End of stream: the phone closed, was killed, or walked out of
            // Wi-Fi range. It is neither an error nor a close frame, and a peer
            // going away does *not* move this connection to `.cancelled` —
            // that state is only for a local cancel. Ignoring it leaves the
            // client listed as connected forever, which showed up as a phone
            // that never received a push because the Mac still thought it was
            // holding a socket.
            //
            // The mirror image of the same hole on the client side, found the
            // same way: by something downstream quietly not happening.
            if data == nil, error == nil, isComplete {
                Task { @MainActor in self.drop(id) }
                return
            }
            // A close frame arrives as a context with that metadata, and as nil
            // data. Anything else with no payload is simply uninteresting.
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                Task { @MainActor in self.drop(id) }
                return
            }
            if let data, !data.isEmpty {
                // Decoded here, on the network queue, on purpose.
                let decoded = Result { try WireCodec.decodeClientFrame(data) }
                Task { @MainActor in self.dispatch(decoded, from: id) }
            }
            self.receive(on: connection, id: id)
        }
    }

    private func dispatch(_ decoded: Result<ClientFrame, any Error>, from id: UUID) {
        switch decoded {
        case .failure:
            send(.failure(WireFailure(
                code: .rejected,
                message: "That message could not be read."
            )), to: id)
        case .success(let frame):
            // Neither applied nor answered in our format. Replying would tell a
            // newer client its write succeeded.
            guard !frame.isFromNewerPeer else {
                send(.failure(WireFailure(
                    code: .versionMismatch,
                    message: "This Mac speaks board protocol \(WireProtocol.version); the app speaks \(frame.version). Update Claude WM."
                )), to: id)
                return
            }
            handler?.handle(frame.message, from: id, on: self)
        }
    }

    // MARK: - Writing

    func send(_ message: ServerMessage, to id: UUID) {
        guard let connection = connections[id] else { return }
        let frame = ServerFrame(message: message)
        guard let data = try? WireCodec.encode(frame) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    /// Only to clients that finished `hello`. A connection that completed the
    /// TLS handshake but not the protocol one has proved it holds the key and
    /// nothing more; board contents are not owed to it yet.
    func broadcast(_ message: ServerMessage) {
        for client in clients where client.isReady {
            send(message, to: client.id)
        }
    }

    // MARK: - Parameters

    private static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        key.withUnsafeBytes { keyBytes in
            let keyData = DispatchData(bytes: keyBytes)
            let identity = Data(pskIdentity.utf8)
            identity.withUnsafeBytes { identityBytes in
                let identityData = DispatchData(bytes: identityBytes)
                sec_protocol_options_add_pre_shared_key(
                    options,
                    keyData as __DispatchData,
                    identityData as __DispatchData
                )
            }
        }
        // PSK needs a ciphersuite naming it explicitly; the defaults are all
        // certificate-based and the handshake fails with no useful diagnosis.
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )

        let parameters = NWParameters(tls: tls)
        // LAN only. Peer-to-peer would let this be reached over AWDL, which is
        // not the promise the pairing UI makes.
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// Constant, and not a secret. TLS-PSK carries an identity alongside the key
    /// so a server can select between several; there is only ever one here.
    static let pskIdentity = "claude-wm-board"

    /// What the phone sees in a list of Macs. The host name rather than a fixed
    /// string, because two Macs on one network advertising "Claude WM" tells the
    /// user nothing about which is theirs.
    static var defaultServiceName: String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return "Claude WM on \(host)"
    }

    /// Shared with the client so both ends build an identical stack.
    ///
    /// **The client must dial an `NWEndpoint.url`, not a host and port.** A
    /// WebSocket connection begins with an HTTP upgrade request, and that
    /// request needs a path and a `Host` header — which host+port cannot supply.
    /// Connecting that way completes the TLS handshake and then aborts with
    /// `POSIXErrorCode(53): Software caused connection abort`, which reads like
    /// a TLS or key problem and is not one. Use `wss://<host>:<port>/`.
    static func clientParameters(key: Data) -> NWParameters { parameters(key: key) }
}

/// What the transport hands its owner. Deliberately not a closure: the service
/// needs to send on the same server it was called from, and a stored closure
/// capturing it would be a retain cycle waiting to happen.
@MainActor
protocol BoardServerHandler: AnyObject {
    func handle(_ message: ClientMessage, from client: UUID, on server: BoardServer)
    /// The connection is gone. Separate from `handle` because it is not a
    /// message — nothing was received, the socket simply ended.
    func clientDisconnected(_ client: UUID)
}
