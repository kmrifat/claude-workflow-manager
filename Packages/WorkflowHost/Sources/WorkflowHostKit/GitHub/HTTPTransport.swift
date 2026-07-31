import Foundation

/// The seam between the GitHub client and the network.
///
/// Exists so tests can drive the client through recorded responses — pagination,
/// 304s and rate limiting are all behaviours worth testing, and none of them
/// should require a network or a token.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.nonHTTPResponse
        }
        return (data, http)
    }
}
