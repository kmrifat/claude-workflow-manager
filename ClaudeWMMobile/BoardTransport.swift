//
//  BoardTransport.swift
//  ClaudeWMMobile
//
//  The phone's copy of the connection parameters, the pairing payload, and
//  Bonjour discovery.
//
//  ## Why this is a copy of the Mac's code and not shared
//
//  `ClaudeWMWire` holds the types both sides speak, and it is deliberately
//  dependency-free and I/O-free — it must not import Network. These few dozen
//  lines are the client half of a protocol whose server half lives in
//  `BoardServer`, and the two must agree exactly. They are kept in step by the
//  loopback test, which builds a client with these parameters against that
//  server.
//
//  If this drifts, the symptom is a TLS handshake that fails with a code no user
//  can act on, so any change to `BoardServer.parameters` has to be made here in
//  the same commit.
//

import Foundation
import Network
import Observation
import ClaudeWMWire
#if os(iOS)
import UIKit
#endif

enum BoardTransport {
    /// Must match `BoardServer.pskIdentity` byte for byte.
    static let pskIdentity = "claude-wm-board"

    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        key.withUnsafeBytes { keyBytes in
            let keyData = DispatchData(bytes: keyBytes)
            let identity = Data(pskIdentity.utf8)
            identity.withUnsafeBytes { identityBytes in
                let identityData = DispatchData(bytes: identityBytes)
                sec_protocol_options_add_pre_shared_key(
                    options,
                    keyData as __DispatchData,
                    identityData as __DispatchData
                )
            }
        }
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t.AES_128_GCM_SHA256)

        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }
}

/// The `claudewm://pair?d=…` payload, decoded on the phone.
///
/// Mirrors `BoardPairing.Payload` on the Mac. Same reason as above: the Mac's
/// version lives in a target this one cannot import.
enum BoardPairingCode {
    struct Payload: Codable, Sendable, Equatable {
        var version: Int
        var key: Data
        var service: String
        var mac: String
    }

    static let keyByteCount = 32

    static func helloToken(for key: Data) -> String { key.base64EncodedString() }

    static func payload(from url: URL) throws -> Payload {
        guard url.scheme == "claudewm", url.host == "pair",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "d" })?.value,
              let json = data(fromBase64URL: raw)
        else { throw PairingError.notAPairingCode }

        let payload = try JSONDecoder().decode(Payload.self, from: json)
        guard payload.key.count == keyByteCount else { throw PairingError.notAPairingCode }
        guard payload.version <= WireProtocol.version else { throw PairingError.needsNewerApp }
        return payload
    }

    enum PairingError: Error, LocalizedError {
        case notAPairingCode
        case needsNewerApp

        var errorDescription: String? {
            switch self {
            case .notAPairingCode: "That isn’t a Claude WM pairing code."
            case .needsNewerApp:   "That Mac is running a newer Claude WM. Update this app to pair with it."
            }
        }
    }

    private static func data(fromBase64URL string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Finds Macs advertising `_claudewm._tcp` on the local network.
///
/// Resolving a *name* rather than remembering an address is the whole reason
/// this exists: an address scanned once is wrong the next time either device
/// gets a new DHCP lease, and a pairing that survives one lease is not a
/// pairing.
@MainActor
@Observable
final class BoardBrowser {
    private(set) var found: [(name: String, endpoint: NWEndpoint)] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_claudewm._tcp", domain: nil), using: .init())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries = results.compactMap { result -> (String, NWEndpoint)? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
            }
            Task { @MainActor in self?.found = entries.map { (name: $0.0, endpoint: $0.1) } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
    }

    /// The endpoint whose Bonjour name matches what the QR code said, if it is
    /// on the network right now.
    func endpoint(named service: String) -> NWEndpoint? {
        found.first { $0.name == service }?.endpoint
    }
}

enum DeviceName {
    #if os(iOS)
    static var current: String { UIDevice.current.name }
    #else
    static var current: String { Host.current().localizedName ?? "Phone" }
    #endif
}
