//
//  BoardPairing.swift
//  workflow-manager
//
//  How a phone comes to hold the key, and how it finds the Mac afterwards.
//
//  ## The QR code is the whole trust story
//
//  Card 4 originally said the QR would carry a token plus a certificate
//  fingerprint to pin. Moving the transport to TLS-PSK (see `BoardServer`)
//  collapsed those two into one: the key *is* the credential and *is* the
//  identity. A peer without it cannot finish a handshake, so there is nothing
//  left to pin and no second secret to keep in step with the first.
//
//  Showing it as a QR code, rather than a code to type, is deliberate: a
//  256-bit key is not typeable, and a key short enough to type is not worth
//  having on a network anyone can join.
//
//  ## On CLAUDE.md's "no credential handling of our own"
//
//  That rule is about GitHub — never read, store or log someone else's token,
//  because `gh` and the Keychain already hold it. This key is not a third
//  party's credential; it is one this app mints for its own LAN protocol, and
//  something has to keep it. The rule it does inherit: it is never logged, never
//  written to the repository, and never leaves the Keychain except to be shown
//  as a QR code the user is looking at.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ClaudeWMWire

enum BoardPairing {
    /// Bonjour type. `_claudewm._tcp` rather than something generic so a phone
    /// browsing the network sees only Macs running this app.
    static let bonjourType = "_claudewm._tcp"

    private static let keychainService = "com.binarycastle.workflow-manager.board-pairing"
    private static let keychainAccount = "pre-shared-key"

    /// 32 bytes. TLS-PSK's strength is the key's, and there is no reason to be
    /// stingy with something nobody types.
    static let keyByteCount = 32

    // MARK: - The key

    static func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // `SecRandomCopyBytes` failing means the system CSPRNG is
            // unavailable. Falling back to anything weaker would produce a key
            // that looks fine and is not, which is worse than no pairing.
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes)
    }

    static func loadKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func storeKey(_ key: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        // Delete-then-add rather than update: an update against a missing item
        // fails, and the two-call dance is the same length either way.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = key
        // The Mac has to be unlocked to serve a board anyway, and this keeps the
        // key out of a backup restored onto another machine.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// How the key is spelled in a `hello` frame: base64, because the wire is
    /// JSON. A helper rather than a convention, so the Mac and the phone cannot
    /// disagree about it — a mismatch here fails *after* a successful TLS
    /// handshake, which is a confusing place to land.
    static func helloToken(for key: Data) -> String {
        key.base64EncodedString()
    }

    /// Existing key, or a freshly minted and stored one.
    static func currentKey() -> Data {
        if let key = loadKey() { return key }
        let key = generateKey()
        storeKey(key)
        return key
    }

    /// Rotating invalidates every paired phone at once — which is the point.
    /// It is the only revocation this design has, and it is the right one for a
    /// single user: there is no device list to get out of step with reality.
    @discardableResult
    static func rotateKey() -> Data {
        let key = generateKey()
        storeKey(key)
        return key
    }

    static func forgetKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
    }

    // MARK: - The payload

    /// What the QR code says.
    ///
    /// The service name, not an address: an IP scanned once is wrong the next
    /// time the Mac joins a network, and a phone that has to be re-paired
    /// because of DHCP would be re-paired constantly.
    struct Payload: Codable, Sendable, Equatable {
        var version: Int
        var key: Data
        var service: String
        var mac: String

        init(version: Int = WireProtocol.version, key: Data, service: String, mac: String) {
            self.version = version
            self.key = key
            self.service = service
            self.mac = mac
        }
    }

    /// `claudewm://pair?d=<base64url>` — a URL so the phone's camera offers to
    /// open it, rather than showing the user a blob of base64 to copy.
    static func url(for payload: Payload) throws -> URL {
        let json = try JSONEncoder().encode(payload)
        var components = URLComponents()
        components.scheme = "claudewm"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "d", value: base64URL(json))]
        guard let url = components.url else {
            throw PairingError.malformedPayload
        }
        return url
    }

    static func payload(from url: URL) throws -> Payload {
        guard url.scheme == "claudewm", url.host == "pair",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "d" })?.value,
              let json = data(fromBase64URL: raw)
        else { throw PairingError.malformedPayload }

        let payload = try JSONDecoder().decode(Payload.self, from: json)
        guard payload.key.count == keyByteCount else { throw PairingError.malformedPayload }
        // Refused rather than tried: a newer Mac may have changed what the key
        // means, and a handshake that half-works is worse than a clear refusal.
        guard payload.version <= WireProtocol.version else { throw PairingError.needsNewerApp }
        return payload
    }

    enum PairingError: Error, LocalizedError {
        case malformedPayload
        case needsNewerApp

        var errorDescription: String? {
            switch self {
            case .malformedPayload:
                "That code isn’t a Claude WM pairing code."
            case .needsNewerApp:
                "That Mac is running a newer Claude WM. Update this app to pair with it."
            }
        }
    }

    // Base64URL, because `+` and `/` in a query value are a standing invitation
    // to a double-encoding bug somewhere between a camera and a URL parser.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64URL string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - The code itself

    /// `.correctionLevel` stays low: the payload is already near the practical
    /// size for a code someone points a phone at, and heavier correction buys
    /// robustness against damage a screen does not suffer.
    static func qrCode(for url: URL, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
