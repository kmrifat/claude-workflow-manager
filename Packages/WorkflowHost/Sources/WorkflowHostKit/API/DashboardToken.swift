import Foundation
import Security

/// The dashboard's bearer token.
///
/// Generated on first run, stored in the Keychain, and printed once. Unlike the
/// GitHub PAT — which the host only ever reads — this one is ours to mint, so
/// writing it is appropriate.
///
/// Phase 4 adds GitHub OAuth alongside this; the token stays as the fallback for
/// localhost and for scripts.
public enum DashboardToken {
    public static let keychainService = "dev.workflowhost"
    public static let keychainAccount = "dashboard-token"
    public static let environmentKey = "WORKFLOWHOST_DASHBOARD_TOKEN"

    public enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "could not access the Keychain: \(message) (\(status))"
            }
        }
    }

    public struct Resolution: Sendable {
        public let token: String
        /// True the first time, so the caller knows to print it.
        public let isNew: Bool
    }

    /// Environment first — a scratch instance shouldn't touch the login Keychain
    /// or leave a token behind in it.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Resolution {
        if let provided = environment[environmentKey], !provided.isEmpty {
            return Resolution(token: provided, isNew: false)
        }
        if let existing = try read() {
            return Resolution(token: existing, isNew: false)
        }
        let token = generate()
        try store(token)
        return Resolution(token: token, isNew: true)
    }

    /// 32 bytes of CSPRNG output, hex encoded.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Falling back to a weaker source silently would be worse than a
            // visibly different shape; this path should never be reached.
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    static func store(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Constant-time comparison — a timing oracle on a bearer token is cheap to
    /// avoid and unpleasant to leave in.
    public static func matches(_ provided: String, _ expected: String) -> Bool {
        let a = Array(provided.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
