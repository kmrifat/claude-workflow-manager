//
//  MCPServer.swift
//  workflow-manager
//
//  Claude WM's MCP server: the boards, as tools, at
//  http://127.0.0.1:7420/mcp over MCP's Streamable HTTP transport.
//
//  This is the replacement for agents editing `.taskboard/tasks.json`. A tool
//  call lands on the board at once, is checked against the board's rules, and
//  shows in the card's activity — none of which a file can do. Both paths
//  coexist for now: a project that syncs its file keeps doing so, and the file
//  simply reflects what MCP changed.
//
//  ## What is implemented of the protocol
//
//  `initialize`, `ping`, `tools/list`, `tools/call`, and notifications. Every
//  POST is answered with one JSON body — the spec lets a server choose JSON over
//  an SSE stream — and GET (a server-initiated stream) is refused with 405, which
//  the spec also allows. Nothing here needs to push to a client, so neither
//  half of SSE earns its complexity.
//
//  ## Who may call it
//
//  Three checks, in order, before any JSON is read:
//
//  - **Host** must be this loopback address — or, with remote access on, one
//    of this Mac's tailnet names. A web page that rebinds its own hostname to
//    127.0.0.1 sends its *own* name as Host; this is the MCP spec's required
//    defence against DNS rebinding.
//  - **Origin**, if present, must be local, for the same reason.
//  - **Authorization** must carry the bearer token from `MCPToken`. Loopback
//    keeps the network out; the token keeps out every other local process.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MCPServer {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        /// Not retried automatically: a taken port does not free itself, and a
        /// silent retry loop would hide that.
        case failed(String)

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    /// One `initialize`d client.
    struct Session: Identifiable, Equatable {
        let id: String
        var clientName: String
        var clientVersion: String
        var protocolVersion: String
        let startedAt: Date
        var lastSeen: Date
        var calls: Int

        var displayName: String {
            clientVersion.isEmpty ? clientName : "\(clientName) \(clientVersion)"
        }
    }

    struct Call: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let client: String
        let tool: String
        let succeeded: Bool
        let message: String?
    }

    static let host = "127.0.0.1"
    static let port: UInt16 = 7420
    static let serverName = "claude-wm"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private static let enabledKey = "mcpServerEnabled"

    private(set) var state: State = .stopped
    private(set) var sessions: [Session] = []
    /// Newest first, capped — enough for Settings to show what just happened.
    private(set) var recentCalls: [Call] = []
    private(set) var token: String = ""
    /// When the listener last came up, for "up 3 h".
    private(set) var runningSince: Date?

    /// Persisted. Off until the user turns it on: opening a port is a decision,
    /// the same rule Phone Access follows.
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: MCPServer.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    let tools = MCPTools()
    private var listener: HTTPListener?

    /// The tailnet node to listen on as well, set by `TailnetAccess`. A second
    /// listener bound to that one address — never 0.0.0.0, so the LAN and any
    /// other interface stay out.
    private(set) var remoteNode: Tailscale.Node?
    private(set) var remoteState: State = .stopped
    private var remoteListener: HTTPListener?

    var url: String { "http://\(Self.host):\(Self.port)/mcp" }

    /// What another Mac on the tailnet dials. Plain HTTP is not a lapse here:
    /// tailnet traffic is WireGuard-encrypted end to end.
    var remoteURL: String? {
        guard remoteState.isRunning, let node = remoteNode else { return nil }
        return "http://\(node.preferredHost):\(Self.port)/mcp"
    }

    var remoteConnectCommand: String? {
        remoteURL.map {
            "claude mcp add --scope user --transport http \(Self.serverName) \($0) --header \"Authorization: Bearer \(token)\""
        }
    }

    /// The line the user pastes into a terminal. `--scope user` registers the
    /// server for every project on this Mac rather than writing it into one
    /// repository — where the token would sit in a file that gets committed.
    var connectCommand: String {
        "claude mcp add --scope user --transport http \(Self.serverName) \(url) --header \"Authorization: Bearer \(token)\""
    }

    // MARK: - Lifecycle

    /// Called once the window has a model context. Starts the server if it was
    /// left on.
    func attach(context: ModelContext) {
        tools.context = context
        if isEnabled { start() }
    }

    func start() {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        loadToken()
        state = .starting

        let listener = makeListener { [weak self] event in self?.listenerEvent(event) }
        self.listener = listener
        listener.start(host: Self.host, port: Self.port)
    }

    private func makeListener(onEvent: @escaping @MainActor (HTTPListener.Event) -> Void) -> HTTPListener {
        HTTPListener(
            handler: { [weak self] request in
                await self?.handle(request) ?? .status(503)
            },
            onEvent: { event in
                Task { @MainActor in onEvent(event) }
            }
        )
    }

    /// Listens on `node` too, or stops doing so for `nil`. Only while the main
    /// server runs: remote access to a server that is off is not a thing.
    func setRemote(_ node: Tailscale.Node?) {
        guard node != remoteNode else { return }
        remoteNode = node
        restartRemote()
    }

    private func restartRemote() {
        remoteListener?.stop()
        remoteListener = nil
        remoteState = .stopped
        guard state.isRunning, let node = remoteNode else { return }

        remoteState = .starting
        let listener = makeListener { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready(let port): remoteState = .running(port: port)
            case .failed(let message):
                remoteListener = nil
                remoteState = .failed(message)
            case .cancelled:
                if case .running = remoteState { remoteState = .stopped }
            }
        }
        remoteListener = listener
        listener.start(host: node.ipv4, port: Self.port)
    }

    func stop() {
        listener?.stop()
        listener = nil
        remoteListener?.stop()
        remoteListener = nil
        remoteState = .stopped
        sessions.removeAll()
        runningSince = nil
        state = .stopped
    }

    /// New token; every configured client must be re-added. Open sessions are
    /// dropped too — a session that outlived its token would be a back door.
    func rotateToken() {
        token = Self.usesSampleData ? "cwm_sample_\(UUID().uuidString.prefix(8))" : MCPToken.rotate()
        sessions.removeAll()
    }

    /// Reads the token without starting anything, so Settings can show the
    /// command before the server is first switched on.
    func loadToken() {
        guard token.isEmpty else { return }
        token = Self.usesSampleData ? "cwm_sample_data_only" : MCPToken.current()
    }

    /// A `-UseSampleData` build keeps its token in memory: a throwaway board
    /// has no business minting a Keychain item for the real one.
    private static var usesSampleData: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-UseSampleData")
        #else
        false
        #endif
    }

    private func listenerEvent(_ event: HTTPListener.Event) {
        switch event {
        case .ready(let port):
            state = .running(port: port)
            runningSince = .now
            restartRemote()
        case .failed(let message):
            listener = nil
            state = .failed(message)
        case .cancelled:
            if case .running = state { state = .stopped }
        }
    }

    // MARK: - HTTP

    /// Loopback always; the tailnet's names only while that listener is up.
    private var allowedHosts: Set<String> {
        var names = ["\(Self.host):\(Self.port)", "localhost:\(Self.port)"]
        if remoteState.isRunning, let node = remoteNode {
            names += node.hostNames.map { "\($0.lowercased()):\(Self.port)" }
        }
        return Set(names)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/mcp" else { return .status(404) }

        let host = (request.header("host") ?? "").lowercased()
        guard allowedHosts.contains(host) else {
            return Self.httpError(403, "Unexpected Host header.")
        }
        if let origin = request.header("origin"), !Self.isLocal(origin: origin) {
            return Self.httpError(403, "Requests from web pages are not accepted.")
        }
        let presented = request.header("authorization")
            .flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil } ?? ""
        guard !token.isEmpty, MCPToken.matches(presented, token) else {
            return Self.httpError(401, "Missing or wrong token. Copy the command from Claude WM › Settings.",
                                  headers: [("WWW-Authenticate", "Bearer realm=\"claude-wm\"")])
        }

        switch request.method {
        case "POST":
            return post(request)
        case "DELETE":
            guard let id = request.header("mcp-session-id"),
                  sessions.contains(where: { $0.id == id }) else { return .status(404) }
            sessions.removeAll { $0.id == id }
            return .status(200)
        default:
            // No server-initiated stream: nothing here ever needs to push.
            return .status(405, headers: [("Allow", "POST, DELETE")])
        }
    }

    private func post(_ request: HTTPRequest) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return Self.rpcResponse(Self.rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }

        // Batches were dropped from the spec in 2025-06-18 but older clients
        // may still send one; answering each message costs nothing.
        let messages = (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]]
        let isInitialize = messages.contains { $0["method"] as? String == "initialize" }

        var session: Session?
        if !isInitialize {
            guard let id = request.header("mcp-session-id") else {
                return Self.httpError(400, "Missing Mcp-Session-Id. Send initialize first.")
            }
            guard let index = sessions.firstIndex(where: { $0.id == id }) else {
                // 404 tells a client its session is gone and it should start a
                // new one — which is what it must do after a token rotation or
                // an app restart.
                return Self.httpError(404, "Unknown session. Initialize again.")
            }
            sessions[index].lastSeen = .now
            session = sessions[index]
        }

        var replies: [[String: Any]] = []
        var newSessionID: String?
        for message in messages {
            guard let method = message["method"] as? String else { continue }  // a response from the client
            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]

            if method == "initialize" {
                let created = startSession(params)
                newSessionID = created.id
                session = created
            }
            guard let id else { continue }  // a notification: nothing to answer

            replies.append(reply(to: method, id: id, params: params, session: session))
        }

        var headers: [(String, String)] = []
        if let newSessionID { headers.append(("Mcp-Session-Id", newSessionID)) }
        guard !replies.isEmpty else { return .status(202, headers: headers) }
        let body: Any = replies.count == 1 && !(json is [Any]) ? replies[0] : replies
        return Self.rpcResponse(body, headers: headers)
    }

    // MARK: - JSON-RPC

    private func reply(to method: String, id: Any, params: [String: Any], session: Session?) -> [String: Any] {
        switch method {
        case "initialize":
            return Self.rpcResult(id: id, [
                "protocolVersion": session?.protocolVersion ?? Self.supportedProtocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": Self.serverName,
                    "title": "Claude WM",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                ],
                "instructions": MCPTools.instructions,
            ])
        case "ping":
            return Self.rpcResult(id: id, [:])
        case "tools/list":
            return Self.rpcResult(id: id, ["tools": MCPTools.definitions.map(\.json)])
        case "tools/call":
            return Self.rpcResult(id: id, callTool(params, session: session))
        default:
            return Self.rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func startSession(_ params: [String: Any]) -> Session {
        let info = params["clientInfo"] as? [String: Any] ?? [:]
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedProtocolVersions.contains(requested)
            ? requested : Self.supportedProtocolVersions[0]
        let session = Session(
            id: UUID().uuidString,
            clientName: info["name"] as? String ?? "MCP client",
            clientVersion: info["version"] as? String ?? "",
            protocolVersion: version,
            startedAt: .now,
            lastSeen: .now,
            calls: 0
        )
        sessions.append(session)
        return session
    }

    /// Tool failures are results with `isError`, not JSON-RPC errors: the model
    /// is meant to read them and adjust, and clients hide protocol errors from it.
    private func callTool(_ params: [String: Any], session: Session?) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let client = session?.displayName ?? "MCP client"

        if let index = sessions.firstIndex(where: { $0.id == session?.id }) {
            sessions[index].calls += 1
        }
        do {
            let result = try tools.call(name, arguments: arguments, client: client)
            log(Call(date: .now, client: client, tool: name, succeeded: true, message: nil))
            return [
                "content": [["type": "text", "text": Self.jsonString(result)]],
                "structuredContent": result,
                "isError": false,
            ]
        } catch {
            let message = (error as? MCPToolError)?.message ?? error.localizedDescription
            log(Call(date: .now, client: client, tool: name, succeeded: false, message: message))
            return [
                "content": [["type": "text", "text": message]],
                "isError": true,
            ]
        }
    }

    private func log(_ call: Call) {
        recentCalls.insert(call, at: 0)
        if recentCalls.count > 50 { recentCalls.removeLast(recentCalls.count - 50) }
    }

    // MARK: - Encoding

    private static func rpcResult(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func rpcResponse(_ body: Any, headers: [(String, String)] = []) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .json(200, data, headers: headers)
    }

    private static func httpError(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return .json(status, body, headers: headers)
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isLocal(origin: String) -> Bool {
        guard let host = URL(string: origin)?.host() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
    }
}
