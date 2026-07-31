//
//  PairedMac.swift
//  ClaudeWMMobile
//
//  The one Mac this phone is paired with.
//
//  Deliberately singular. A device list would need a way to name, pick between
//  and forget entries, and the Mac's revocation story is a single key it can
//  rotate — so a phone holding several would be showing state the Mac cannot
//  confirm. One pairing, re-scan to change it.
//

import Foundation
import Security

struct PairedMac: Equatable {
    var key: Data
    var service: String
    var macName: String
}

enum PairedMacStore {
    private static let keychainService = "com.binarycastle.claude-wm-mobile.pairing"
    private static let keychainAccount = "pre-shared-key"
    private static let serviceKey = "pairedServiceName"
    private static let macNameKey = "pairedMacName"

    static func load() -> PairedMac? {
        guard let key = loadKey(),
              let service = UserDefaults.standard.string(forKey: serviceKey)
        else { return nil }
        return PairedMac(
            key: key,
            service: service,
            macName: UserDefaults.standard.string(forKey: macNameKey) ?? service
        )
    }

    static func save(_ pairing: PairedMac) {
        storeKey(pairing.key)
        UserDefaults.standard.set(pairing.service, forKey: serviceKey)
        UserDefaults.standard.set(pairing.macName, forKey: macNameKey)
    }

    static func forget() {
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: serviceKey)
        UserDefaults.standard.removeObject(forKey: macNameKey)
    }

    // MARK: - Keychain
    //
    // The key goes in the Keychain rather than UserDefaults because it is a
    // credential: a plist is readable from a backup, and this one grants write
    // access to somebody's board.

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func loadKey() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func storeKey(_ key: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key
        // Not `ThisDeviceOnly`: restoring a backup onto a replacement phone and
        // finding your board still works is the behaviour a user expects, and
        // the Mac can revoke by rotating its key if that is not wanted.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
