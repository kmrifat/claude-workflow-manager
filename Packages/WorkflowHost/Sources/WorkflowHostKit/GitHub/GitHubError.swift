import Foundation

public enum GitHubError: Error, CustomStringConvertible, Equatable {
    case nonHTTPResponse
    /// The request budget is spent. Carries the moment it refills, so the poller
    /// can wait exactly that long instead of hammering.
    case rateLimited(resetAt: Date)
    case unauthorized
    case notFound(path: String)
    case httpFailure(status: Int, path: String, message: String?)
    case decodingFailure(path: String, reason: String)
    /// GraphQL answers 200 with an `errors` array; a partial success is still a
    /// failure for our purposes.
    case graphQLErrors([String])

    public var description: String {
        switch self {
        case .nonHTTPResponse:
            return "GitHub returned a non-HTTP response"
        case .rateLimited(let resetAt):
            return "rate limited until \(resetAt.formatted(.iso8601))"
        case .unauthorized:
            return "GitHub rejected the token (401) — check its scopes and expiry"
        case .notFound(let path):
            return "GitHub returned 404 for \(path)"
        case .httpFailure(let status, let path, let message):
            return "GitHub returned \(status) for \(path)\(message.map { " — \($0)" } ?? "")"
        case .decodingFailure(let path, let reason):
            return "could not decode the response from \(path) — \(reason)"
        case .graphQLErrors(let messages):
            return "GraphQL errors: \(messages.joined(separator: "; "))"
        }
    }

    /// Whether the poller should keep going. Everything here is transient or
    /// scoped to one repo — the loop must never die on a GitHub problem.
    public var isRetryable: Bool {
        switch self {
        case .unauthorized: return false
        default: return true
        }
    }
}
