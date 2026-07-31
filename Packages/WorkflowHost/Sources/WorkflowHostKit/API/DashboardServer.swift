import Foundation
import Vapor
import WorkflowCore

/// Serves the API, the WebSocket, and one static page.
///
/// Handlers are nonisolated `async` and hold `AppDatabase` directly, so a
/// dashboard read never queues behind the dispatcher — that is the whole reason
/// the database layer is not an actor.
public struct DashboardServer: Sendable {
    private let state: StateBuilder
    private let runs: RunStore
    private let hub: EventHub
    private let token: String
    private let controls: DashboardControls?

    /// Actions the dashboard can trigger. Absent until the dispatcher exists,
    /// which keeps phases 3–5 strictly read-only.
    public protocol DashboardControls: Sendable {
        func stopRun(id: Int64) async throws
    }

    public init(
        state: StateBuilder,
        runs: RunStore,
        hub: EventHub,
        token: String,
        controls: DashboardControls? = nil
    ) {
        self.state = state
        self.runs = runs
        self.hub = hub
        self.token = token
        self.controls = controls
    }

    public func register(on app: Application) throws {
        let state = state
        let runs = runs
        let hub = hub
        let token = token
        let controls = controls

        // MARK: Static page

        app.get { request async throws -> Response in
            let html = try Self.indexHTML()
            return Response(
                status: .ok,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: .init(string: html)
            )
        }

        // MARK: API

        let api = app.grouped("api").grouped(BearerTokenMiddleware(token: token))

        api.get("state") { request async throws -> DashboardState in
            await state.build()
        }

        api.get("runs", ":id") { request async throws -> RunDetail in
            guard let id = request.parameters.get("id", as: Int64.self) else {
                throw Abort(.badRequest, reason: "run id must be an integer")
            }
            guard let detail = await state.runDetail(id: id) else {
                throw Abort(.notFound, reason: "no run \(id)")
            }
            return detail
        }

        api.get("events") { request async throws -> [EventRecord] in
            let limit = request.query[Int.self, at: "limit"] ?? 100
            return try runs.recentEvents(limit: min(max(limit, 1), 500))
        }

        api.post("runs", ":id", "stop") { request async throws -> HTTPStatus in
            guard let id = request.parameters.get("id", as: Int64.self) else {
                throw Abort(.badRequest, reason: "run id must be an integer")
            }
            guard let controls else {
                throw Abort(.serviceUnavailable, reason: "the dispatcher is not running")
            }
            try await controls.stopRun(id: id)
            await hub.broadcast()
            return .ok
        }

        // MARK: WebSocket
        //
        // Pushes a nudge rather than a payload; the page re-fetches. It also
        // polls on focus, because iOS kills background sockets and a silently
        // dead socket must not look like a quiet system.

        app.webSocket("ws", shouldUpgrade: { request async throws -> HTTPHeaders? in
            guard Self.isAuthorised(request, token: token) else {
                throw Abort(.unauthorized)
            }
            return [:]
        }) { request, socket async in
            let stream = await hub.subscribe()
            Task {
                for await signal in stream {
                    try? await socket.send(signal.rawValue)
                }
                try? await socket.close()
            }
            try? await socket.onClose.get()
        }
    }

    static func isAuthorised(_ request: Request, token: String) -> Bool {
        if let bearer = request.headers.bearerAuthorization?.token,
           DashboardToken.matches(bearer, token) {
            return true
        }
        // A browser cannot set headers on a WebSocket handshake or a plain
        // navigation, so the token is also accepted as a query parameter.
        if let query = request.query[String.self, at: "token"],
           DashboardToken.matches(query, token) {
            return true
        }
        return false
    }

    static func indexHTML() throws -> String {
        guard let url = Bundle.module.url(forResource: "Resources/index", withExtension: "html")
                ?? Bundle.module.url(forResource: "index", withExtension: "html")
        else {
            throw Abort(.internalServerError, reason: "dashboard page missing from the bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Bearer token, or `?token=` for the browser.
struct BearerTokenMiddleware: AsyncMiddleware {
    let token: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard DashboardServer.isAuthorised(request, token: token) else {
            throw Abort(.unauthorized, reason: "missing or invalid token")
        }
        return try await next.respond(to: request)
    }
}

// The DTOs are already Codable; this is all Vapor needs to return them directly.
// Not `@retroactive` — WorkflowCore is in the same package.
extension DashboardState: Content {}
extension RunDetail: Content {}
extension EventRecord: Content {}
