import Foundation
import WorkflowCore

/// Read-only access to GitHub.
///
/// Stateless by design: rate-limit information is *returned* rather than
/// remembered, so the poller stays the single owner of backoff (see the
/// concurrency rule in CLAUDE.md). That keeps this a `Sendable` value type that
/// any subsystem can hold.
public struct GitHubClient: Sendable {
    private let token: String
    private let transport: any HTTPTransport
    private let restBase: URL
    private let graphQLURL: URL

    // Exposed to the write extension in phase 6. Kept internal, not public:
    // callers outside this module go through the typed methods.
    var restBaseURL: URL { restBase }
    var transportForWrites: any HTTPTransport { transport }

    func applyHeaders(to request: inout URLRequest) {
        applyStandardHeaders(to: &request)
    }

    /// Runs a GraphQL request for its side effect, checking the `errors` array.
    /// Used by the board mutation, which has no payload worth decoding.
    @discardableResult
    func graphQLRaw(_ request: GraphQLRequest) async throws -> Data {
        var urlRequest = URLRequest(url: graphQLURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(request)
        applyStandardHeaders(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.send(urlRequest)
        let rateLimit = RateLimit(headers: response.allHeaderFields)
        try check(response, path: "/graphql", data: data, rateLimit: rateLimit)

        struct Envelope: Decodable {
            struct Failure: Decodable { let message: String }
            let errors: [Failure]?
        }
        if let errors = try? JSONDecoder().decode(Envelope.self, from: data).errors, !errors.isEmpty {
            throw GitHubError.graphQLErrors(errors.map(\.message))
        }
        return data
    }

    public init(
        token: String,
        transport: any HTTPTransport = URLSessionTransport(),
        restBase: URL = URL(string: "https://api.github.com")!,
        graphQLURL: URL = URL(string: "https://api.github.com/graphql")!
    ) {
        self.token = token
        self.transport = transport
        self.restBase = restBase
        self.graphQLURL = graphQLURL
    }

    // MARK: - REST

    public func repository(owner: String, name: String) async throws -> GitHubResponse<RepositoryInfo> {
        let path = "/repos/\(owner)/\(name)"
        let outcome = try await perform(.get, path: path, query: [], ifNoneMatch: nil)
        guard case .body(let data, _, let rateLimit) = outcome else {
            // No conditional request was made, so 304 is not reachable here.
            throw GitHubError.httpFailure(status: 304, path: path, message: "unexpected 304")
        }
        let wire: WireRepository = try decode(data, path: path)
        return GitHubResponse(
            value: RepositoryInfo(owner: owner, name: name, defaultBranch: wire.defaultBranch),
            rateLimit: rateLimit
        )
    }

    /// Open issues, newest activity first.
    ///
    /// GitHub's issues endpoint also returns pull requests; those are filtered
    /// out here so `issues` means issues everywhere upstream of this call.
    public func issues(
        owner: String,
        name: String,
        ifNoneMatch etag: String? = nil
    ) async throws -> GitHubResponse<Conditional<[GitHubIssue]>> {
        try await collection(
            path: "/repos/\(owner)/\(name)/issues",
            ifNoneMatch: etag
        ) { (wire: [WireIssue]) in
            wire.filter { $0.pullRequest == nil }.map(\.asIssue)
        }
    }

    public func pullRequests(
        owner: String,
        name: String,
        ifNoneMatch etag: String? = nil
    ) async throws -> GitHubResponse<Conditional<[GitHubPullRequest]>> {
        try await collection(
            path: "/repos/\(owner)/\(name)/pulls",
            ifNoneMatch: etag
        ) { (wire: [WirePullRequest]) in
            wire.map(\.asPullRequest)
        }
    }

    /// Fetches every page, using the caller's ETag on the first request only.
    ///
    /// `sort=updated&direction=desc` is what makes the single ETag trustworthy:
    /// any change to any item in the collection reorders page one, so a 304 on
    /// page one really does mean nothing changed.
    private func collection<Wire: Decodable, Value: Sendable>(
        path: String,
        ifNoneMatch etag: String?,
        transform: ([Wire]) -> [Value]
    ) async throws -> GitHubResponse<Conditional<[Value]>> {
        var query = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
        ]

        var collected: [Value] = []
        var firstPageETag: String?
        var lastRateLimit: RateLimit?
        var page = 1

        while true {
            let outcome = try await perform(
                .get,
                path: path,
                query: query,
                ifNoneMatch: page == 1 ? etag : nil
            )

            switch outcome {
            case .notModified(let rateLimit):
                return GitHubResponse(value: .notModified, rateLimit: rateLimit)

            case .body(let data, let response, let rateLimit):
                lastRateLimit = rateLimit
                if page == 1 {
                    firstPageETag = header(response, "etag")
                }
                collected.append(contentsOf: transform(try decode(data, path: path)))

                guard let next = nextPage(from: header(response, "link")) else {
                    return GitHubResponse(
                        value: .fetched(collected, etag: firstPageETag),
                        rateLimit: lastRateLimit
                    )
                }
                page = next
                query.removeAll { $0.name == "page" }
                query.append(URLQueryItem(name: "page", value: String(next)))
            }
        }
    }

    // MARK: - GraphQL

    /// The board, including every card's column. Paginated over project items.
    public func projectSnapshot(
        owner: String,
        name: String,
        number: Int
    ) async throws -> GitHubResponse<ProjectSnapshot> {
        var cursor: String?
        var items: [ProjectItem] = []
        var project: BoardSnapshotPayload.Project?
        var lastRateLimit: RateLimit?

        while true {
            let request = GraphQLRequest(
                query: GitHubGraphQL.boardSnapshot,
                variables: [
                    "owner": .string(owner),
                    "name": .string(name),
                    "number": .int(number),
                    "cursor": cursor.map { .string($0) } ?? .null,
                ]
            )

            let response: GitHubResponse<BoardSnapshotPayload> = try await graphQL(request)
            lastRateLimit = response.rateLimit

            guard let page = response.value.repository?.projectV2 else {
                throw GitHubError.notFound(path: "\(owner)/\(name) project #\(number)")
            }
            project = page
            items.append(contentsOf: page.items.nodes.map(\.asProjectItem))

            guard page.items.pageInfo.hasNextPage, let next = page.items.pageInfo.endCursor else {
                break
            }
            cursor = next
        }

        guard let project else {
            throw GitHubError.notFound(path: "\(owner)/\(name) project #\(number)")
        }

        return GitHubResponse(
            value: ProjectSnapshot(
                projectId: project.id,
                number: project.number,
                title: project.title,
                statusField: project.field.map {
                    ProjectStatusField(
                        id: $0.id,
                        name: $0.name,
                        options: $0.options.map { ProjectStatusOption(id: $0.id, name: $0.name) }
                    )
                },
                items: items
            ),
            rateLimit: lastRateLimit
        )
    }

    private func graphQL<Payload: Decodable>(
        _ request: GraphQLRequest
    ) async throws -> GitHubResponse<Payload> {
        var urlRequest = URLRequest(url: graphQLURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(request)
        applyStandardHeaders(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.send(urlRequest)
        let rateLimit = RateLimit(headers: response.allHeaderFields)
        try check(response, path: "/graphql", data: data, rateLimit: rateLimit)

        let envelope: GraphQLResponse<Payload> = try decode(data, path: "/graphql")
        // GraphQL reports failures with a 200, and a partial result is still a
        // failure for us — caching half a board is worse than not caching it.
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubError.graphQLErrors(errors.map(\.message))
        }
        guard let payload = envelope.data else {
            throw GitHubError.decodingFailure(path: "/graphql", reason: "response had no data")
        }
        return GitHubResponse(value: payload, rateLimit: rateLimit)
    }

    // MARK: - Plumbing

    private enum Method: String {
        case get = "GET"
    }

    private enum Outcome {
        case notModified(RateLimit?)
        case body(Data, HTTPURLResponse, RateLimit?)
    }

    private func perform(
        _ method: Method,
        path: String,
        query: [URLQueryItem],
        ifNoneMatch etag: String?
    ) async throws -> Outcome {
        var components = URLComponents(
            url: restBase.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw GitHubError.decodingFailure(path: path, reason: "could not build a URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        applyStandardHeaders(to: &request)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await transport.send(request)
        let rateLimit = RateLimit(headers: response.allHeaderFields)

        if response.statusCode == 304 {
            return .notModified(rateLimit)
        }
        try check(response, path: path, data: data, rateLimit: rateLimit)
        return .body(data, response, rateLimit)
    }

    private func applyStandardHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("WorkflowHost/\(HostBoot.version)", forHTTPHeaderField: "User-Agent")
    }

    private func check(
        _ response: HTTPURLResponse,
        path: String,
        data: Data,
        rateLimit: RateLimit?
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 401:
            throw GitHubError.unauthorized

        case 403, 429:
            // 403 is overloaded: it means both "rate limited" and "your token
            // may not do that". Only the former carries an exhausted budget or a
            // Retry-After, so use those to tell them apart.
            if let retryAfter = header(response, "retry-after").flatMap(Double.init) {
                throw GitHubError.rateLimited(resetAt: Date().addingTimeInterval(retryAfter))
            }
            if let rateLimit, rateLimit.remaining == 0 {
                throw GitHubError.rateLimited(resetAt: rateLimit.resetAt)
            }
            throw GitHubError.httpFailure(
                status: response.statusCode, path: path, message: errorMessage(data)
            )

        case 404:
            throw GitHubError.notFound(path: path)

        default:
            throw GitHubError.httpFailure(
                status: response.statusCode, path: path, message: errorMessage(data)
            )
        }
    }

    private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decodingFailure(path: path, reason: String(describing: error))
        }
    }

    private func errorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { let message: String? }
        return try? JSONDecoder().decode(Envelope.self, from: data).message
    }

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }

    /// Reads the page number out of the `Link` header's `rel="next"` entry.
    /// Following the URL wholesale would be neater, but rebuilding from the page
    /// number keeps every request going through the same query construction.
    func nextPage(from linkHeader: String?) -> Int? {
        guard let linkHeader else { return nil }

        for link in linkHeader.split(separator: ",") {
            let parts = link.split(separator: ";")
            guard parts.count >= 2 else { continue }
            let isNext = parts.dropFirst().contains { $0.contains("rel=\"next\"") }
            guard isNext else { continue }

            let raw = parts[0].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let components = URLComponents(string: raw),
                  let page = components.queryItems?.first(where: { $0.name == "page" })?.value
            else { continue }
            return Int(page)
        }
        return nil
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Wire types
//
// GitHub's REST shapes, kept here so their snake_case and their nesting never
// reach WorkflowCore or the clients.

private struct WireRepository: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

private struct WireIssue: Decodable {
    struct Label: Decodable { let name: String }
    struct User: Decodable { let login: String }
    /// Present only when the "issue" is really a pull request.
    struct PullRequestMarker: Decodable {}

    let number: Int
    let title: String
    let htmlURL: URL
    let state: String
    let labels: [Label]
    let assignees: [User]
    let body: String?
    let updatedAt: Date
    let pullRequest: PullRequestMarker?

    enum CodingKeys: String, CodingKey {
        case number, title, state, labels, assignees, body
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    var asIssue: GitHubIssue {
        GitHubIssue(
            number: number,
            title: title,
            url: htmlURL,
            state: state,
            labels: labels.map(\.name),
            assignees: assignees.map(\.login),
            body: body,
            updatedAt: updatedAt
        )
    }
}

private struct WirePullRequest: Decodable {
    struct Ref: Decodable { let ref: String }

    let number: Int
    let title: String
    let htmlURL: URL
    let state: String
    let draft: Bool?
    let head: Ref
    let base: Ref
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case number, title, state, draft, head, base
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }

    var asPullRequest: GitHubPullRequest {
        GitHubPullRequest(
            number: number,
            title: title,
            url: htmlURL,
            state: state,
            isDraft: draft ?? false,
            headRef: head.ref,
            baseRef: base.ref,
            updatedAt: updatedAt
        )
    }
}

extension BoardSnapshotPayload.Item {
    var asProjectItem: ProjectItem {
        ProjectItem(
            id: id,
            status: fieldValueByName?.name,
            content: content.map { content in
                ProjectItemContent(
                    kind: content.__typename == "PullRequest" ? .pullRequest : .issue,
                    number: content.number,
                    title: content.title,
                    url: content.url,
                    state: content.state,
                    assignees: content.assignees?.nodes.map(\.login) ?? []
                )
            }
        )
    }
}
