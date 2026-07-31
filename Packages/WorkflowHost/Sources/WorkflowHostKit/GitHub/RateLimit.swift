import Foundation

/// The rate-limit state GitHub reports on every response.
///
/// REST and GraphQL have separate budgets; this describes whichever one the
/// response came from.
public struct RateLimit: Sendable, Equatable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date

    public init(limit: Int, remaining: Int, resetAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// Leaves a little headroom rather than polling until the budget is exactly
    /// zero — a tick costs several requests, and being locked out mid-tick is
    /// worse than waiting one interval.
    public var isNearlyExhausted: Bool { remaining <= 5 }

    public init?(headers: [AnyHashable: Any]) {
        func value(_ name: String) -> String? {
            // Header names are case-insensitive; GitHub sends them lowercased,
            // but URLSession may canonicalise them differently.
            for (key, value) in headers where (key as? String)?.lowercased() == name {
                return value as? String
            }
            return nil
        }

        guard let limit = value("x-ratelimit-limit").flatMap(Int.init),
              let remaining = value("x-ratelimit-remaining").flatMap(Int.init),
              let reset = value("x-ratelimit-reset").flatMap(Double.init)
        else { return nil }

        self.limit = limit
        self.remaining = remaining
        self.resetAt = Date(timeIntervalSince1970: reset)
    }
}

/// A decoded response plus whatever the rate-limit headers said about it.
public struct GitHubResponse<Value: Sendable>: Sendable {
    public let value: Value
    public let rateLimit: RateLimit?

    public init(value: Value, rateLimit: RateLimit?) {
        self.value = value
        self.rateLimit = rateLimit
    }

    public func map<Other: Sendable>(_ transform: (Value) throws -> Other) rethrows -> GitHubResponse<Other> {
        GitHubResponse<Other>(value: try transform(value), rateLimit: rateLimit)
    }
}

/// The result of a conditional request.
public enum Conditional<Value: Sendable>: Sendable {
    /// The server answered 304 — the cached copy is still current.
    case notModified
    case fetched(Value, etag: String?)
}
