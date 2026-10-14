//
//  TunnelGateway.swift
//  workflow-manager
//
//  The one local address a Cloudflare Tunnel points at, `127.0.0.1:7423`. It
//  reads a request's first line and splices the connection to the service the
//  path names:
//
//      /mcp…    → the MCP server     (127.0.0.1:7420)
//      /board…  → Phone Access relay (127.0.0.1:7422)
//      anything else → 404
//
//  One address, so a your-domain tunnel needs one public hostname in the
//  Cloudflare dashboard and a quick tunnel needs one `cloudflared`. Everything
//  after the first line is bytes; the services do their own checking — the
//  MCP token, the sealed handshake — and the gateway adds nothing to either.
//
//  **Ordinary requests are made `Connection: close`.** `cloudflared` keeps idle
//  connections to its origin and reuses them, and the routing decision is
//  made once per connection — so a connection spliced to the MCP server for
//  one request could later be handed a phone's WebSocket upgrade and send it
//  to the wrong place. Closing after each plain request makes every request
//  start a fresh connection and be routed on its own path. An upgrade keeps
//  its connection, which is then the WebSocket's alone.
//
//  Bound to loopback only: it exists for `cloudflared` on this Mac, not for
//  the network.
//

import Foundation
import Network

@MainActor
final class TunnelGateway {
    /// One per app: there is one tunnel, and one port to bind.
    static let shared = TunnelGateway()

    static let port: UInt16 = 7423
    static let mcpPort: UInt16 = MCPServer.port
    static let relayPort: UInt16 = BoardServer.relayPort

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.binarycastle.workflow-manager.tunnel-gateway")

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: parameters) else { return }
        let queue = queue
        listener.newConnectionHandler = { connection in
            GatewayConnection(client: connection, queue: queue).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// The routing decision, apart from sockets. Pure, so it can be checked.
enum GatewayRoute: Equatable {
    case mcp
    case relay
    case notFound

    static func route(path: String) -> GatewayRoute {
        if path == "/mcp" || path.hasPrefix("/mcp?") || path.hasPrefix("/mcp/") { return .mcp }
        if path == "/board" || path.hasPrefix("/board?") || path.hasPrefix("/board/") { return .relay }
        return .notFound
    }

    /// The path from a request head, or nil if the head is not HTTP/1.x.
    static func path(inHead head: String) -> String? {
        guard let line = head.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        return String(parts[1])
    }

    /// The head with `Connection: close`, unless it asks for an upgrade, which
    /// must keep its connection. See the file comment for why.
    static func closingAfterResponse(_ head: String) -> String {
        var lines = head.components(separatedBy: "\r\n")
        let isUpgrade = lines.contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix("connection:") && lower.contains("upgrade")
        }
        guard !isUpgrade else { return head }
        lines.removeAll { $0.lowercased().hasPrefix("connection:") }
        // Before the blank line that ends the head.
        let end = lines.lastIndex(where: { !$0.isEmpty }).map { $0 + 1 } ?? lines.count
        lines.insert("Connection: close", at: end)
        return lines.joined(separator: "\r\n")
    }
}

/// One spliced connection. Lives until either side closes.
private final class GatewayConnection: @unchecked Sendable {
    private static let maxHead = 32 * 1024
    private let client: NWConnection
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer = Data()
    private var finishedDirections = 0
    private var me: GatewayConnection?

    init(client: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.queue = queue
    }

    func start() {
        me = self
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHead()
        // A client that never finishes a head does not get to hold a socket.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.upstream == nil { self?.close() }
        }
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                route(headEnd: end.lowerBound)
            } else if error != nil || isComplete || buffer.count > Self.maxHead {
                close()
            } else {
                readHead()
            }
        }
    }

    private func route(headEnd: Data.Index) {
        let head = String(decoding: buffer[..<headEnd], as: UTF8.self)
        let rest = buffer[buffer.index(headEnd, offsetBy: 4)...]
        let port: UInt16
        switch GatewayRoute.route(path: GatewayRoute.path(inHead: head) ?? "") {
        case .mcp: port = TunnelGateway.mcpPort
        case .relay: port = TunnelGateway.relayPort
        case .notFound:
            let body = "Not found\n"
            let response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }

        let forwarded = Data((GatewayRoute.closingAfterResponse(head) + "\r\n\r\n").utf8) + rest
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                upstream.send(content: forwarded, completion: .contentProcessed { _ in })
                pump(from: client, to: upstream)
                pump(from: upstream, to: client)
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil { return close() }
            if isComplete {
                // Half-close towards the other side and let it finish: one side
                // being done sending does not mean its answer has arrived.
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in })
                finishedDirections += 1
                if finishedDirections == 2 { close() }
                return
            }
            pump(from: source, to: destination)
        }
    }

    private func close() {
        client.cancel()
        upstream?.cancel()
        upstream = nil
        me = nil
    }
}
