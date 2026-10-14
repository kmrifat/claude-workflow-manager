//
//  A real phone, a real Mac, over a real TLS-PSK socket.
//
//  Everything here is the app's own code — BoardServer, BoardService,
//  RepositoryService, TerminalSession, a real `zsh` on a real pty — with a
//  client built from the wire types the phone uses. Nothing is mocked, so a
//  drift between the two ends shows up as a failed check rather than as a bug
//  someone finds on a train.
//

import AppKit
import Foundation
import Network
import SwiftData
import ClaudeWMWire

// MARK: - Harness plumbing

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print(condition ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !condition { failures += 1 }
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// The phone's half: dial the endpoint, speak the wire, collect what comes back.
@MainActor
final class TestClient {
    private var connection: NWConnection?
    var received: [ServerMessage] = []
    private let queue = DispatchQueue(label: "loopback.client")

    func connect(port: UInt16, key: Data) {
        // The client must dial an `NWEndpoint.url`, not host+port: the upgrade
        // is an HTTP request that needs a path and a Host header. Host+port
        // completes the TLS handshake and *then* aborts with POSIX 53.
        //
        // Built by the phone's own `remoteEndpoint`, the path a phone away from
        // the Wi-Fi takes to a Mac's tailnet name — so this covers it too.
        let endpoint = BoardTransport.remoteEndpoint(host: "127.0.0.1", port: port)!
        let connection = NWConnection(to: endpoint, using: BoardTransport.parameters(key: key))
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    func send(_ message: ClientMessage) {
        guard let connection, let data = try? WireCodec.encode(ClientFrame(message: message)) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }
            if let data, let frame = try? WireCodec.decodeServerFrame(data) {
                Task { @MainActor in self.received.append(frame.message) }
            }
            self.receive(on: connection)
        }
    }

    /// Waits for a message matching `predicate`, pumping the run loop.
    func waitFor(
        _ label: String,
        timeout: TimeInterval = 6,
        _ predicate: @escaping (ServerMessage) -> Bool
    ) -> ServerMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = received.first(where: predicate) { return match }
            pump(0.1)
        }
        return nil
    }

    func drop() { connection?.cancel() }
}

/// The phone's half through a Cloudflare Tunnel, minus Cloudflare: plain
/// WebSocket to the gateway, then the sealed handshake and sealed frames —
/// exactly what the relay sees once `cloudflared` has unwrapped TLS.
@MainActor
final class RelayTestClient {
    private var connection: NWConnection?
    private(set) var received: [ServerMessage] = []
    private(set) var closed = false
    private let key: Data
    private let clientNonce = SealedChannel.makeNonce()
    private let state = RelayClientState()
    private var pending: [ClientMessage] = []
    private let queue = DispatchQueue(label: "loopback.relay")

    init(key: Data) { self.key = key }

    /// - Parameter url: the gateway by default; a real tunnel's `wss://`
    ///   address for the live check, with `tls` on.
    func connect(sealed: Bool = true, url: URL? = nil, tls: Bool = false) {
        let url = url ?? URL(string: "ws://127.0.0.1:\(TunnelGateway.port)/board")!
        let parameters = tls ? NWParameters(tls: NWProtocolTLS.Options()) : NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        let nonce = clientNonce
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                if sealed {
                    Task { @MainActor in self?.sendRaw(SealedChannel.handshake(nonce: nonce), opcode: .binary) }
                }
            case .failed, .cancelled:
                Task { @MainActor in self?.closed = true }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    func send(_ message: ClientMessage) {
        guard let session = state.session else { pending.append(message); return }
        guard let data = try? WireCodec.encode(ClientFrame(message: message)),
              let sealed = try? session.seal(data) else { return }
        sendRaw(sealed, opcode: .binary)
    }

    func sendPlain(_ message: ClientMessage) {
        guard let data = try? WireCodec.encode(ClientFrame(message: message)) else { return }
        sendRaw(data, opcode: .text)
    }

    private func sendRaw(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        connection?.send(content: data, contentContext: .init(identifier: "f", metadata: [metadata]),
                         completion: .contentProcessed { _ in })
    }

    private func handshakeDone(_ serverNonce: Data) {
        state.session = SealedChannel.session(pairingKey: key, clientNonce: clientNonce,
                                              serverNonce: serverNonce, isServer: false)
        let queued = pending
        pending.removeAll()
        queued.forEach(send)
    }

    private func receive(on connection: NWConnection) {
        let state = state
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (data == nil && isComplete) {
                Task { @MainActor in self.closed = true }
                return
            }
            if let data, !data.isEmpty {
                if let session = state.session {
                    if let plain = try? session.open(data), let frame = try? WireCodec.decodeServerFrame(plain) {
                        Task { @MainActor in self.received.append(frame.message) }
                    }
                } else if let nonce = try? SealedChannel.nonce(fromHandshake: data) {
                    // Set before the next receive, so a sealed frame right
                    // behind the handshake is not mistaken for another one.
                    state.session = SealedChannel.session(pairingKey: self.key, clientNonce: self.clientNonce,
                                                          serverNonce: nonce, isServer: false)
                    Task { @MainActor in self.flush() }
                }
            }
            self.receive(on: connection)
        }
    }

    private func flush() {
        let queued = pending
        pending.removeAll()
        queued.forEach(send)
    }

    func waitFor(_ timeout: TimeInterval = 6, _ predicate: @escaping (ServerMessage) -> Bool) -> ServerMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = received.first(where: predicate) { return match }
            pump(0.1)
        }
        return nil
    }

    func waitUntilClosed(_ timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !closed { pump(0.1) }
        return closed
    }

    func drop() { connection?.cancel() }
}

private final class RelayClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: SealedSession?
    var session: SealedSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }
}

/// One raw HTTP exchange through the gateway; the response as text.
@MainActor
func httpThroughGateway(_ request: String) -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: TunnelGateway.port)!, using: .tcp)
    let collected = RelayCollected()
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        }
    }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { collected.append(data) }
            if isComplete || error != nil { collected.finish(); return }
            read()
        }
    }
    connection.start(queue: DispatchQueue(label: "loopback.http"))
    read()
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline, !collected.isFinished { pump(0.05) }
    connection.cancel()
    return collected.text
}

private final class RelayCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    func finish() { lock.withLock { finished = true } }
    var isFinished: Bool { lock.withLock { finished } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

// MARK: - A repository to look at

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "loopback-repo-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try? "# Hello\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
try? FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
try? "let x = 1\n".write(to: root.appending(path: "Sources/main.swift"), atomically: true, encoding: .utf8)

// A secret outside the repository, and a symlink inside it that points at the
// secret's directory. String rules alone cannot catch this one.
let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "loopback-outside")
try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try? "TOP SECRET\n".write(to: outside.appending(path: "id_rsa"), atomically: true, encoding: .utf8)
try? FileManager.default.createSymbolicLink(
    at: root.appending(path: "escape"),
    withDestinationURL: outside
)

// MARK: - The Mac

let schema = Schema([Project.self, BoardColumn.self, WorkItem.self, TerminalCommand.self])
let container = try ModelContainer(
    for: schema,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
)

let outcome: Void = try MainActor.assumeIsolated {
    let context = ModelContext(container)

    let project = Project(name: "Loopback")
    project.repoPath = root.path
    context.insert(project)

    let command = TerminalCommand(name: "greeter", command: "echo READY_FROM_SAVED_COMMAND")
    command.project = project
    context.insert(command)
    try context.save()

    let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    let server = BoardServer()
    let service = BoardService(context: context, expectedToken: { key })
    let terminals = TerminalStateStore()
    service.attachRepositoryAccess(terminals: terminals)
    server.handler = service
    // The fixed port remote access uses, so the dial below is the one a phone
    // makes over Tailscale: a known port, no Bonjour.
    server.start(key: key, serviceName: "Loopback Harness", port: TailnetAccess.phonePort)

    // The pairing code survives the trip from the Mac's encoder to the
    // phone's decoder with the tailnet host and port intact — and a code
    // without them still decodes, which is what keeps old codes working.
    let remoteCode = try? BoardPairing.url(for: BoardPairing.Payload(
        key: key, service: "Loopback Harness", mac: "Loopback Harness",
        host: "harness.tail-test.ts.net", port: TailnetAccess.phonePort
    ))
    let decoded = remoteCode.flatMap { try? BoardPairingCode.payload(from: $0) }
    check("pairing code carries the tailnet host to the phone",
          decoded?.host == "harness.tail-test.ts.net" && decoded?.port == TailnetAccess.phonePort)
    let plainCode = try? BoardPairing.url(for: BoardPairing.Payload(key: key, service: "S", mac: "M"))
    let plain = plainCode.flatMap { try? BoardPairingCode.payload(from: $0) }
    check("a code without a host still pairs", plain != nil && plain?.host == nil)

    var port: UInt16 = 0
    for _ in 0..<50 {
        if case .running(let running) = server.state { port = running; break }
        pump(0.1)
    }
    guard port != 0 else {
        print("  FAIL server never started: \(server.state)")
        failures += 1
        return
    }
    print("Server on port \(port)")

    let projectID = project.uuid.uuidString
    let client = TestClient()
    client.connect(port: port, key: key)
    client.send(.hello(token: key.base64EncodedString(), clientName: "Harness"))
    guard client.waitFor("welcome", { if case .welcome = $0 { true } else { false } }) != nil else {
        print("  FAIL never got welcome — TLS or hello failed")
        failures += 1
        return
    }
    print("\n1. The gate is closed by default")

    RemoteAccess.isEnabled = false
    client.received.removeAll()
    client.send(.listTerminals(projectID: projectID))
    let refusal = client.waitFor("forbidden") {
        if case .failure(let failure) = $0 { failure.code == .forbidden } else { false }
    }
    check("a terminal request is refused while the setting is off", refusal != nil)
    check("nothing was listed anyway", !client.received.contains { $0.type == "terminals" })

    client.received.removeAll()
    client.send(.readFile(projectID: projectID, path: "README.md"))
    check(
        "a file request is refused too",
        client.waitFor("forbidden file") {
            if case .failure(let failure) = $0 { failure.code == .forbidden } else { false }
        } != nil
    )

    print("\n2. Turning it on takes effect on a live connection")

    RemoteAccess.isEnabled = true
    client.received.removeAll()
    client.send(.listTerminals(projectID: projectID))
    let listed = client.waitFor("terminals") { if case .terminals = $0 { true } else { false } }
    guard case .terminals(_, let refs)? = listed else {
        print("  FAIL no terminal list arrived")
        failures += 1
        return
    }
    check("the saved command is offered as a session", refs.contains { $0.title.contains("greeter") },
          "got \(refs.map(\.title))")
    check("and it is not running yet", refs.allSatisfy { !$0.isRunning })

    guard let session = refs.first else {
        print("  FAIL no session to attach to")
        failures += 1
        return
    }

    print("\n3. Attach, start, and watch a real shell")

    client.received.removeAll()
    client.send(.attachTerminal(projectID: projectID, sessionID: session.id))
    check(
        "the Mac answers with a screen to paint",
        client.waitFor("attached") { if case .terminalAttached = $0 { true } else { false } } != nil
    )

    client.send(.terminalAction(sessionID: session.id, action: .start))
    let started = client.waitFor("running") {
        if case .terminalState(_, let ref) = $0 { ref.isRunning } else { false }
    }
    check("starting it is reported back", started != nil)

    // The saved command is typed into the shell after it settles, so its output
    // is what proves the whole chain: pty → session → relay → socket → phone.
    var sawSavedCommand = false
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline, !sawSavedCommand {
        pump(0.2)
        let output = client.received.compactMap { message -> Data? in
            if case .terminalOutput(_, let data) = message { data } else { nil }
        }
        let text = output.reduce(into: Data()) { $0.append($1) }
        sawSavedCommand = String(decoding: text, as: UTF8.self).contains("READY_FROM_SAVED_COMMAND")
    }
    check("the saved command's output reached the phone", sawSavedCommand)

    print("\n4. Typing on the phone reaches the shell")

    client.received.removeAll()
    client.send(.terminalInput(
        sessionID: session.id,
        data: Data("echo TYPED_ON_PHONE\r".utf8)
    ))
    var sawTyped = false
    let typedDeadline = Date().addingTimeInterval(8)
    while Date() < typedDeadline, !sawTyped {
        pump(0.2)
        let text = client.received.compactMap { message -> Data? in
            if case .terminalOutput(_, let data) = message { data } else { nil }
        }.reduce(into: Data()) { $0.append($1) }
        // The echoed *result*, not the echoed keystrokes: the line discipline
        // echoes what was typed either way, so matching the command text alone
        // would pass without the shell ever running it.
        sawTyped = String(decoding: text, as: UTF8.self)
            .components(separatedBy: "TYPED_ON_PHONE").count > 2
    }
    check("the shell ran what the phone typed", sawTyped)

    print("\n5. Files, and the paths that must not be served")

    client.received.removeAll()
    client.send(.listDirectory(projectID: projectID, path: ""))
    let listing = client.waitFor("directory") { if case .directory = $0 { true } else { false } }
    guard case .directory(_, _, let entries)? = listing else {
        print("  FAIL no directory listing")
        failures += 1
        return
    }
    check("the repository root lists its files", entries.contains { $0.name == "README.md" })
    check("paths are repository-relative, never absolute",
          entries.allSatisfy { !$0.path.hasPrefix("/") }, "got \(entries.map(\.path))")

    client.received.removeAll()
    client.send(.readFile(projectID: projectID, path: "README.md"))
    let read = client.waitFor("file") { if case .fileContent = $0 { true } else { false } }
    if case .fileContent(_, _, .text(let text))? = read {
        check("a file comes back with its contents", text.contains("Hello"))
    } else {
        check("a file comes back with its contents", false, "got \(String(describing: read))")
    }

    for escape in ["../loopback-outside/id_rsa", "/etc/passwd", "escape/id_rsa", "Sources/../../loopback-outside/id_rsa"] {
        client.received.removeAll()
        client.send(.readFile(projectID: projectID, path: escape))
        let answer = client.waitFor("escape \(escape)", timeout: 3) {
            if case .failure = $0 { true } else if case .fileContent = $0 { true } else { false }
        }
        var refused = false
        if case .failure(let failure)? = answer, failure.code == .unreadablePath { refused = true }
        check("refuses “\(escape)”", refused, "got \(String(describing: answer))")
    }

    print("\n6. A phone that leaves stops being mirrored")

    client.drop()
    pump(1.0)
    // The session is still running on the Mac — dropping a phone must not kill
    // a dev server — but nothing is being sent to it any more.
    let stillRunning = terminals.session(UUID(uuidString: session.id)!)?.isRunning ?? false
    check("the shell outlives the phone", stillRunning)

    print("\n7. Through a Cloudflare Tunnel")

    // The pieces that do not need a socket.
    let relayCode = try? BoardPairing.url(for: BoardPairing.Payload(
        key: key, service: "S", mac: "M", relay: "https://harness.trycloudflare.com"
    ))
    check("pairing code carries the tunnel address to the phone",
          relayCode.flatMap { try? BoardPairingCode.payload(from: $0) }?.relay == "https://harness.trycloudflare.com")
    if case .url(let dial)? = BoardTransport.relayEndpoint("https://pitwall.example.com") {
        check("the phone dials wss://<host>/board", dial.absoluteString == "wss://pitwall.example.com/board", dial.absoluteString)
    } else {
        check("the phone dials wss://<host>/board", false)
    }
    check("gateway routes /mcp", GatewayRoute.route(path: "/mcp") == .mcp)
    check("gateway routes /board", GatewayRoute.route(path: "/board") == .relay)
    check("gateway refuses anything else", GatewayRoute.route(path: "/") == .notFound
          && GatewayRoute.route(path: "/mcpx") == .notFound && GatewayRoute.route(path: "/admin") == .notFound)
    let plainHead = "POST /mcp HTTP/1.1\r\nHost: x\r\nConnection: keep-alive"
    check("a plain request is closed after its response",
          GatewayRoute.closingAfterResponse(plainHead).hasSuffix("Connection: close")
          && !GatewayRoute.closingAfterResponse(plainHead).contains("keep-alive"))
    let upgradeHead = "GET /board HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket"
    check("an upgrade keeps its connection", GatewayRoute.closingAfterResponse(upgradeHead) == upgradeHead)
    let quickLog = """
    2026-10-15T00:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
    2026-10-15T00:00:01Z INF |  https://mild-otter-sample-tunnel.trycloudflare.com  |
    """
    check("quick tunnel address read from cloudflared's log",
          CloudflaredLog.quickTunnelURL(in: quickLog)?.absoluteString == "https://mild-otter-sample-tunnel.trycloudflare.com")
    check("api.trycloudflare.com is not mistaken for a tunnel",
          CloudflaredLog.quickTunnelURL(in: "ERR failed to reach https://api.trycloudflare.com/tunnel") == nil)
    check("a named tunnel is up once a connection registers",
          CloudflaredLog.isConnected("INF Registered tunnel connection connIndex=0 location=lhr01"))
    check("the last error is reported plainly",
          CloudflaredLog.failure(in: "2026-10-15T00:00:00Z ERR Provided Tunnel token is not valid.") == "Provided Tunnel token is not valid.")
    check("a pasted install command yields the token",
          CloudflareTunnel.token(fromPasted: "sudo cloudflared service install eyJhIjoiYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo0MjQyNDI0MiJ9")
          == "eyJhIjoiYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo0MjQyNDI0MiJ9")
    check("a hostname is cleaned of scheme and slashes",
          CloudflareTunnel.clean(" https://Pitwall.Example.com/ ") == "pitwall.example.com")

    // The relay and the gateway, for real.
    server.relayURL = "https://harness.trycloudflare.com"
    server.startRelay()
    TunnelGateway.shared.start()
    pump(0.5)
    check("the relay is listening on loopback", server.isRelayRunning)

    let phone = RelayTestClient(key: key)
    phone.connect()
    phone.send(.hello(token: key.base64EncodedString(), clientName: "Tunnel phone"))
    let tunnelWelcome = phone.waitFor { if case .welcome = $0 { true } else { false } }
    check("a paired phone gets in through the gateway, sealed", tunnelWelcome != nil)
    if case .welcome(_, let relay)? = tunnelWelcome {
        check("welcome tells the phone the tunnel's current address", relay == "https://harness.trycloudflare.com")
    }
    phone.send(.listProjects)
    let projectsReply = phone.waitFor { if case .projects = $0 { true } else { false } }
    if case .projects(let list)? = projectsReply {
        check("the board answers over the sealed link", list.contains { $0.name == "Loopback" })
    } else {
        check("the board answers over the sealed link", false)
    }

    let stranger = RelayTestClient(key: Data(repeating: 0xAB, count: 32))
    stranger.connect()
    stranger.send(.hello(token: key.base64EncodedString(), clientName: "Stranger"))
    check("a phone without the pairing key is dropped", stranger.waitUntilClosed())
    check("…before it hears anything from the board", stranger.received.isEmpty)

    let unsealed = RelayTestClient(key: key)
    unsealed.connect(sealed: false)
    pump(0.3)
    unsealed.sendPlain(.hello(token: key.base64EncodedString(), clientName: "Plain"))
    check("an unsealed client is dropped", unsealed.waitUntilClosed())
    check("…and sees no board", unsealed.received.isEmpty)

    let notFound = httpThroughGateway("GET /admin HTTP/1.1\r\nHost: x\r\n\r\n")
    check("the gateway answers 404 to anything but /mcp and /board", notFound.hasPrefix("HTTP/1.1 404"), notFound)

    // /mcp reaches whatever listens on the MCP port, with Connection: close.
    let echo = HTTPListener(
        handler: { request in
            HTTPResponse.status(200, headers: [("X-Saw-Connection", request.header("connection") ?? "none")])
        },
        onEvent: { _ in }
    )
    echo.start(host: MCPServer.host, port: MCPServer.port)
    pump(0.4)
    let mcpReply = httpThroughGateway("GET /mcp HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
    check("/mcp is spliced to the MCP port", mcpReply.hasPrefix("HTTP/1.1 200"), String(mcpReply.prefix(80)))
    check("…closed after the response, so the next request is routed afresh",
          mcpReply.lowercased().contains("x-saw-connection: close"), mcpReply)
    echo.stop()

    phone.drop()

    // A real quick tunnel through Cloudflare, opt-in: it puts this Mac on a
    // public address for as long as it runs. `LOOPBACK_CLOUDFLARE=1`.
    if ProcessInfo.processInfo.environment["LOOPBACK_CLOUDFLARE"] == "1" {
        print("\n8. Live, through Cloudflare")
        let tunnel = CloudflareTunnel.shared
        tunnel.mode = .quick
        tunnel.start()
        var address: URL?
        for _ in 0..<300 {
            if let url = tunnel.state.url { address = url; break }
            if case .failed(let message) = tunnel.state { print("  cloudflared failed: \(message)"); break }
            pump(0.1)
        }
        check("cloudflared reports a quick tunnel address", address != nil, "\(tunnel.state)")
        if let address, let dial = BoardTransport.relayEndpoint(address.absoluteString),
           case .url(let wss) = dial {
            print("  tunnel: \(address.absoluteString)")
            // A brand-new hostname can take a moment to resolve.
            var livePhone: RelayTestClient?
            var liveWelcome: ServerMessage?
            for attempt in 1...8 {
                let client = RelayTestClient(key: key)
                client.connect(url: wss, tls: true)
                client.send(.hello(token: key.base64EncodedString(), clientName: "Live phone"))
                liveWelcome = client.waitFor(8) { if case .welcome = $0 { true } else { false } }
                if liveWelcome != nil { livePhone = client; break }
                client.drop()
                print("  attempt \(attempt): not yet")
                pump(3)
            }
            check("a paired phone gets in through Cloudflare, over real TLS, sealed", liveWelcome != nil)
            livePhone?.send(.listProjects)
            check("…and the board answers through Cloudflare",
                  livePhone?.waitFor(8) { if case .projects = $0 { true } else { false } } != nil)

            let liveStranger = RelayTestClient(key: Data(repeating: 0xCD, count: 32))
            liveStranger.connect(url: wss, tls: true)
            liveStranger.send(.hello(token: key.base64EncodedString(), clientName: "Stranger"))
            check("a phone without the key is dropped through Cloudflare too",
                  liveStranger.waitUntilClosed(10) && liveStranger.received.isEmpty)
            livePhone?.drop()
        }
        tunnel.stop()
        pump(0.5)
    }

    TunnelGateway.shared.stop()
    server.stopRelay()

    terminals.session(UUID(uuidString: session.id)!)?.stop()
    server.stop()
    RemoteAccess.isEnabled = false
    pump(0.5)
}

try? FileManager.default.removeItem(at: root)
try? FileManager.default.removeItem(at: outside)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
