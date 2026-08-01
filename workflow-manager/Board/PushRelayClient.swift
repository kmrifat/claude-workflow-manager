//
//  PushRelayClient.swift
//  workflow-manager
//
//  Sends a card move to the push relay, which holds the APNs key.
//
//  ## Why this is the shipping path and `APNsClient` is not
//
//  `APNsClient` talks to Apple directly, which needs the `.p8` on this Mac.
//  That is right for the person who owns the key and wrong for everyone else:
//  a key bundled into a copy you sell can be extracted, and being account-wide
//  it would let the extractor push to every app on the account.
//
//  The relay does not remove the leak, it shrinks it. The key apps carry here is
//  still extractable — but it only opens this relay, only to device tokens the
//  holder would have to already know, and it can be rotated by redeploying.
//
//  ## Configuration is baked, not asked for
//
//  Read from `Info.plist` at build time, so a shipped app already knows where to
//  send and the user is never shown a text field. `UserDefaults` overrides it,
//  which is the seam a self-hoster uses and nobody else ever sees.
//

import Foundation
import ClaudeWMWire

/// An actor for the same reason `APNsClient` is: it is shared across concurrent
/// sends and owns the session. (Actors are already nonisolated — no modifier.)
actor PushRelayClient {
    enum Failure: Error, LocalizedError {
        case rejected(status: Int, reason: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let status, let reason):
                "The push relay refused this (\(status) \(reason))."
            case .transport(let detail):
                detail
            }
        }
    }

    struct Configuration: Sendable, Equatable {
        var url: URL
        var key: String

        /// Baked at build time, overridable for self-hosting. Absent in a
        /// development build, which is why the direct `APNsClient` path still
        /// exists alongside this one.
        static func current() -> Configuration? {
            let defaults = UserDefaults.standard
            let bundle = Bundle.main.infoDictionary

            let rawURL = defaults.string(forKey: "pushRelayURL")
                ?? bundle?["ClaudeWMPushRelayURL"] as? String
            let key = defaults.string(forKey: "pushRelayKey")
                ?? bundle?["ClaudeWMPushRelayKey"] as? String

            guard let rawURL, let url = URL(string: rawURL), !rawURL.isEmpty,
                  let key, !key.isEmpty
            else { return nil }
            return Configuration(url: url, key: key)
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func send(_ notice: CardMoveNotice, to deviceToken: String) async throws {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // No `environment`: the relay tries sandbox then production and knows
        // which worked. Deciding here would mean this Mac guessing what kind of
        // build is on somebody's phone.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": deviceToken,
            "title": notice.title,
            "subtitle": notice.subtitle,
            "body": notice.body,
            "collapseID": notice.identifier,
            "threadID": notice.threadIdentifier,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("No response from the push relay.")
        }
        guard http.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["reason"] ?? $0?["error"]) as? String } ?? "unknown"
            throw Failure.rejected(status: http.statusCode, reason: reason)
        }
    }
}
