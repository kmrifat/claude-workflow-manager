import Foundation
import Testing
@testable import WorkflowHostKit

/// A scripted `HTTPTransport`.
///
/// Tests drive the client through recorded responses so pagination, 304s and
/// rate limiting can be exercised without a network or a token.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: String = "[]"
        var headers: [String: String] = [:]
    }

    /// Called with each request; returns the reply to send back.
    private let handler: @Sendable (URLRequest, Int) -> Reply
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.handler = handler
    }

    /// Replies with a fixed sequence, one per request.
    convenience init(replies: [Reply]) {
        let box = Mutex(replies)
        self.init { _, index in
            box.withLock { $0.indices.contains(index) ? $0[index] : Reply(status: 500, body: "{}") }
        }
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = lock.withLock {
            _requests.append(request)
            return _requests.count - 1
        }
        let reply = handler(request, index)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (Data(reply.body.utf8), response)
    }
}

/// Minimal mutex so the stub can hold state without being an actor — the
/// transport protocol is synchronous-friendly and tests read it after the fact.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

extension URLRequest {
    var queryItems: [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }
}

/// Rate-limit headers with plenty of budget left.
func healthyRateLimitHeaders(remaining: Int = 4_000) -> [String: String] {
    [
        "x-ratelimit-limit": "5000",
        "x-ratelimit-remaining": String(remaining),
        "x-ratelimit-reset": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
    ]
}
