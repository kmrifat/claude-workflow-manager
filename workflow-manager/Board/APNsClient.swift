//
//  APNsClient.swift
//  workflow-manager
//
//  Pushes a card move to a sleeping phone, with the Mac acting as its own APNs
//  provider.
//
//  ## Why there is no server here
//
//  A push provider is an HTTP/2 POST to Apple carrying a JWT you signed. That is
//  all it is. `URLSession` negotiates HTTP/2 by itself and `CryptoKit` signs
//  ES256, so the Mac that already knows the board can talk to Apple directly.
//  Renting a server to relay a message from a Mac to a phone in the same house
//  would be the only shared backend in the product, and it would exist purely to
//  work around iOS suspending a socket.
//
//  ## The key cannot ship
//
//  The `.p8` is an account-wide credential: anyone holding it can push to every
//  install of this app. Fine on your own Mac, where you put it there. Not fine
//  inside a copy you sell, which is why `PushCredentials` makes the user supply
//  it and never bundles one.
//
//  ## Sandbox versus production
//
//  A development build registers with the sandbox and gets a token the
//  production host rejects with `BadDeviceToken` — a 400 that reads like a bug in
//  your token handling and is not. There is no way to tell from the token which
//  it is, so this tries one host, and on exactly that error retries the other and
//  remembers which worked.
//

import Foundation
import CryptoKit
import ClaudeWMWire

/// An actor: the JWT cache and the learned host are mutable state shared across
/// concurrent sends, and an actor is the one owner of them. (No `nonisolated`
/// modifier — an actor already is.)
actor APNsClient {
    enum Failure: Error, LocalizedError {
        case badKey(String)
        case rejected(status: Int, reason: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .badKey(let detail):
                "That doesn’t look like a valid APNs key (.p8): \(detail)"
            case .rejected(let status, let reason):
                "Apple rejected the push (\(status) \(reason))."
            case .transport(let detail):
                detail
            }
        }
    }

    struct Credentials: Sendable, Equatable {
        var keyID: String
        var teamID: String
        var bundleID: String
        /// The PEM text of the `.p8`, exactly as downloaded.
        var privateKeyPEM: String
    }

    private let credentials: Credentials
    private let session: URLSession

    /// Apple throttles token generation and rejects a JWT older than an hour.
    /// Re-signing per push would get you rate-limited; this refreshes well
    /// inside both bounds.
    private var cachedToken: (value: String, issued: Date)?
    private static let tokenLifetime: TimeInterval = 45 * 60

    /// Which host this phone's tokens belong to, once we know.
    private var host: Host?

    private enum Host: String {
        case production = "api.push.apple.com"
        case sandbox = "api.sandbox.push.apple.com"

        var other: Host { self == .production ? .sandbox : .production }
    }

    init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: - Sending

    func send(_ notice: CardMoveNotice, to deviceToken: String) async throws {
        // A development build is the common case while any of this is being
        // built, so start there and let the fallback correct it.
        let first = host ?? .sandbox
        do {
            try await post(notice, to: deviceToken, host: first)
            host = first
        } catch Failure.rejected(_, let reason) where reason == "BadDeviceToken" {
            try await post(notice, to: deviceToken, host: first.other)
            host = first.other
        }
    }

    private func post(_ notice: CardMoveNotice, to deviceToken: String, host: Host) async throws {
        var request = URLRequest(url: URL(string: "https://\(host.rawValue)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(try authenticationToken())", forHTTPHeaderField: "authorization")
        request.setValue(credentials.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        // 10 = deliver now. A card move is only interesting while it is news;
        // `apns-collapse-id` means a second move of the same card replaces the
        // first on the lock screen rather than stacking.
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(notice.identifier.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
        request.setValue(
            String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            forHTTPHeaderField: "apns-expiration"
        )

        let payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": notice.title,
                    "subtitle": notice.subtitle,
                    "body": notice.body,
                ],
                "thread-id": notice.threadIdentifier,
                "interruption-level": "active",
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("No HTTP response from APNs.")
        }
        guard http.statusCode == 200 else {
            // Apple's body is `{"reason":"BadDeviceToken"}`, and the reason is
            // the only actionable part — the status alone never tells you which
            // of a dozen things went wrong.
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["reason"] as? String } ?? "unknown"
            throw Failure.rejected(status: http.statusCode, reason: reason)
        }
    }

    // MARK: - JWT
    //
    // ES256 over `{"alg":"ES256","kid":…}.{"iss":team,"iat":now}`. The signature
    // is raw r‖s, not DER — `rawRepresentation` is already that, and using
    // `derRepresentation` here is the classic way to get a 403 InvalidProviderToken
    // that looks like a wrong key.

    private func authenticationToken() throws -> String {
        if let cachedToken, Date().timeIntervalSince(cachedToken.issued) < Self.tokenLifetime {
            return cachedToken.value
        }

        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw Failure.badKey(error.localizedDescription)
        }

        let header = ["alg": "ES256", "kid": credentials.keyID]
        let payload: [String: Any] = [
            "iss": credentials.teamID,
            "iat": Int(Date().timeIntervalSince1970),
        ]

        let signingInput = try [header, payload]
            .map { try base64URL(JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
            .joined(separator: ".")

        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        let token = signingInput + "." + base64URL(signature)
        cachedToken = (token, Date())
        return token
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
