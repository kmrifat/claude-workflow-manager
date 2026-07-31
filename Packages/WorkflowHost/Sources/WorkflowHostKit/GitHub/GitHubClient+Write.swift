import Foundation
import WorkflowCore

/// The only writes the host ever performs.
///
/// Everything before phase 6 is read-only; these three exist because dispatching
/// requires them. Note what is *not* here: nothing merges a PR, closes an issue,
/// or force-pushes. Every run ends at "PR opened" and waits for a human.
extension GitHubClient {
    /// Claims an issue. **This is the cross-machine lock** — it must succeed
    /// before any local work starts, so a second host sees the claim and skips.
    public func assignIssue(
        owner: String,
        name: String,
        number: Int,
        to assignee: String
    ) async throws {
        _ = try await send(
            method: "POST",
            path: "/repos/\(owner)/\(name)/issues/\(number)/assignees",
            body: ["assignees": .array([.string(assignee)])]
        )
    }

    /// Releases a claim, so a failed dispatch doesn't strand the issue.
    public func unassignIssue(
        owner: String,
        name: String,
        number: Int,
        from assignee: String
    ) async throws {
        _ = try await send(
            method: "DELETE",
            path: "/repos/\(owner)/\(name)/issues/\(number)/assignees",
            body: ["assignees": .array([.string(assignee)])]
        )
    }

    /// Opens a pull request. Draft by default — a run's output is a proposal,
    /// not a claim that it is ready.
    public func openPullRequest(
        owner: String,
        name: String,
        title: String,
        head: String,
        base: String,
        body: String,
        draft: Bool = true
    ) async throws -> GitHubPullRequest {
        let data = try await send(
            method: "POST",
            path: "/repos/\(owner)/\(name)/pulls",
            body: [
                "title": .string(title),
                "head": .string(head),
                "base": .string(base),
                "body": .string(body),
                "draft": .bool(draft),
            ]
        )

        struct Wire: Decodable {
            let number: Int
            let title: String
            let html_url: URL
            let state: String
            let draft: Bool?
            let updated_at: Date
        }
        let wire = try Self.decoder.decode(Wire.self, from: data)
        return GitHubPullRequest(
            number: wire.number,
            title: wire.title,
            url: wire.html_url,
            state: wire.state,
            isDraft: wire.draft ?? draft,
            headRef: head,
            baseRef: base,
            updatedAt: wire.updated_at
        )
    }

    /// Moves a board card. The mutation itself lives in `ProjectBoardMutation`,
    /// which resolves the column name to an option id so a config typo fails
    /// here rather than silently doing nothing at GitHub.
    public func moveCard(
        _ item: ProjectItem,
        to column: String,
        in snapshot: ProjectSnapshot
    ) async throws {
        let request = try ProjectBoardMutation.moveCard(item, to: column, in: snapshot)
        _ = try await graphQLRaw(request)
    }

    // MARK: - Plumbing

    private func send(
        method: String,
        path: String,
        body: [String: JSONValue]
    ) async throws -> Data {
        var request = URLRequest(url: restBaseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transportForWrites.send(request)
        let rateLimit = RateLimit(headers: response.allHeaderFields)

        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if let rateLimit, rateLimit.remaining == 0 {
                throw GitHubError.rateLimited(resetAt: rateLimit.resetAt)
            }
            throw GitHubError.httpFailure(status: response.statusCode, path: path, message: Self.message(data))
        case 404:
            throw GitHubError.notFound(path: path)
        default:
            throw GitHubError.httpFailure(status: response.statusCode, path: path, message: Self.message(data))
        }
    }

    static func message(_ data: Data) -> String? {
        struct Envelope: Decodable { let message: String? }
        return try? JSONDecoder().decode(Envelope.self, from: data).message
    }
}

/// Just enough JSON to build request bodies without `Any`.
enum JSONValue: Encodable, Sendable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        }
    }
}
