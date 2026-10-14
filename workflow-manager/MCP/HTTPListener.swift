//
//  HTTPListener.swift
//  workflow-manager
//
//  Just enough HTTP/1.1 to carry MCP's Streamable HTTP transport: one request
//  at a time per connection, `Content-Length` bodies, keep-alive. Transport
//  only — what a request *means* is `MCPServer`'s problem, the same split as
//  `BoardServer` and `BoardService`.
//
//  ## Why hand-written
//
//  Vapor cannot be a dependency of this target (see CLAUDE.md), and the phone
//  server dodged HTTP by speaking only WebSocket. MCP cannot: its transport is
//  a POST per message. The subset it needs is small, and everything outside it
//  is refused rather than half-supported — no chunked request bodies (Node's
//  `fetch`, which Claude Code uses, sends a length), no pipelining surprises
//  (requests on a connection are answered strictly in order), and hard limits
//  on header and body size so a misbehaving local process cannot grow the
//  buffer without bound.
//
//  ## Threading
//
//  Network.framework delivers on `queue`; parsing happens there, and only the
//  parsed request hops to the main actor. Everything mutable in here is touched
//  only on `queue`, which is what makes `@unchecked Sendable` honest.
//

import Foundation
import Network

nonisolated struct HTTPRequest: Sendable {
    var method: String
    /// Without the query string.
    var path: String
    /// Lowercased names. A repeated header keeps its last value — nothing MCP
    /// sends repeats one.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func json(_ status: Int, _ body: Data, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    static func status(_ status: Int, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    var reason: String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}

nonisolated final class HTTPListener: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum Event: Sendable {
        case ready(UInt16)
        case failed(String)
        case cancelled
    }

    private let queue = DispatchQueue(label: "com.binarycastle.workflow-manager.mcp-http")
    private let handler: Handler
    private let onEvent: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(handler: @escaping Handler, onEvent: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
        self.onEvent = onEvent
    }

    /// Binds to `host:port` exactly — `127.0.0.1` means the server is not on
    /// the network at all, not merely unadvertised.
    func start(host: String, port: UInt16) {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .any
            )
            parameters.allowLocalEndpointReuse = true

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                onEvent(.failed(error.localizedDescription))
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    onEvent(.ready(listener.port?.rawValue ?? port))
                case .failed(let error):
                    onEvent(.failed(Self.describe(error, port: port)))
                    listener.cancel()
                case .cancelled:
                    onEvent(.cancelled)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            for connection in connections.values { connection.close() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = HTTPConnection(connection: connection, queue: queue, handler: handler)
        let id = ObjectIdentifier(wrapped)
        wrapped.onClose = { [weak self] in self?.connections[id] = nil }
        connections[id] = wrapped
        wrapped.start()
    }

    /// "Address already in use" is the failure people will actually meet — a
    /// second copy of the app, or something else on the port — so say that
    /// rather than quoting POSIX.
    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use. Is another copy of Pitwall running?"
        }
        return error.localizedDescription
    }
}

/// One TCP connection. Requests are answered strictly in order: the next one is
/// not parsed until the current response has been written.
nonisolated private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 4 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPListener.Handler
    private var buffer = Data()
    private var isBusy = false
    private var isClosed = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPListener.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            processBuffer()
            if isComplete || error != nil {
                // The peer finished sending. Let an in-flight response go out
                // first; `send` closes once it is written.
                if !isBusy { close() }
                return
            }
            receive()
        }
    }

    private func processBuffer() {
        guard !isBusy, !isClosed else { return }
        switch parse() {
        case .incomplete:
            return
        case .invalid(let response):
            respond(response, closeAfter: true)
        case .request(let request, let consumed):
            buffer = Data(buffer.dropFirst(consumed))
            isBusy = true
            let keepAlive = request.header("connection")?.lowercased() != "close"
            Task { [handler] in
                let response = await handler(request)
                self.queue.async { self.respond(response, closeAfter: !keepAlive) }
            }
        }
    }

    private func respond(_ response: HTTPResponse, closeAfter: Bool) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n"
        head += closeAfter ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            isBusy = false
            if closeAfter { close() } else { processBuffer() }
        })
    }

    private enum ParseResult {
        case incomplete
        case invalid(HTTPResponse)
        case request(HTTPRequest, consumed: Int)
    }

    private func parse() -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeaderBytes ? .invalid(.status(431)) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(.status(400))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(.status(400)) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil { return .invalid(.status(411)) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(.status(400)) }
        guard length <= Self.maxBodyBytes else { return .invalid(.status(413)) }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .incomplete }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
        return .request(request, consumed: buffer.distance(from: buffer.startIndex, to: bodyEnd))
    }
}
