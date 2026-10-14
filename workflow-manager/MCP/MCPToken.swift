//
//  MCPToken.swift
//  workflow-manager
//
//  The bearer token an MCP client must send. Minted here, kept in the
//  Keychain, shown only inside the "connect" command the user copies.
//
//  Same footing as `BoardPairing`'s key: it is not someone else's credential —
//  the CLAUDE.md rule about never handling tokens is about GitHub's — but one
//  this app mints for its own server. It inherits that rule's spirit: never
//  logged, never written into a repository.
//
//  Why a token at all on a loopback-only port: any local process, and any web
//  page via a DNS-rebound hostname, can reach 127.0.0.1. The Host and Origin
//  checks in `MCPServer` stop the browser; the token stops everything else.
//

import Foundation
import Security

nonisolated enum MCPToken {
    private static let keychainService = "com.binarycastle.workflow-manager.mcp"
    private static let keychainAccount = "bearer-token"

    /// Existing token, or a freshly minted and stored one.
    static func current() -> String {
        if let token = load() { return token }
        return rotate()
    }

    /// Mints a new token. Every client configured with the old one stops
    /// working, which is the point: it is the only revocation there is.
    @discardableResult
    static func rotate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // As in `BoardPairing.generateKey`: a weaker fallback would yield a
            // token that looks fine and is not.
            fatalError("SecRandomCopyBytes failed")
        }
        let token = "cwm_" + bytes.map { String(format: "%02x", $0) }.joined()
        store(token)
        return token
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func store(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Constant-time comparison, so response timing says nothing about how
    /// much of a guess was right.
    static func matches(_ candidate: String, _ token: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
