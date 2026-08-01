//
//  PushRegistry.swift
//  workflow-manager
//
//  The APNs credentials, the phones that have registered, and the rule about
//  when to push instead of doing nothing.
//
//  ## Push only what a local notification cannot reach
//
//  A connected phone already posts its own notification the moment the board
//  changes — it is holding a socket and diffing snapshots. Pushing to it as well
//  gives the user two banners for one event. So a push goes only to devices that
//  are *not* currently connected, which is precisely the case local
//  notifications cannot cover and the only reason APNs is here at all.
//
//  ## The key
//
//  Kept in the Keychain, never bundled, and supplied by whoever runs the app. An
//  APNs auth key is account-wide: anyone holding it can push to every install of
//  this app, so shipping one inside a copy you sell would hand that to each
//  buyer. `BoardSharingView` is where a person pastes their own.
//

import Foundation
import Security
import ClaudeWMWire

@MainActor
@Observable
final class PushRegistry {
    static let shared = PushRegistry()

    private static let keychainService = "com.binarycastle.workflow-manager.apns"
    private static let keychainAccount = "auth-key-p8"
    private static let keyIDKey = "apnsKeyID"
    private static let teamIDKey = "apnsTeamID"
    private static let tokensKey = "apnsDeviceTokens"

    /// The phone's own bundle identifier — the `apns-topic`. Not this app's:
    /// the push is addressed to the iOS client.
    static let phoneBundleID = "com.binarycastle.claude-wm-mobile"

    private(set) var lastError: String?

    /// `deviceID` → APNs token. Survives launches, because the point is to reach
    /// a phone that is not here.
    private var tokens: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.tokensKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokensKey) }
    }

    /// Which devices hold a live socket right now, by `deviceID`.
    private var connected: Set<String> = []

    private var client: APNsClient?

    private init() {}

    // MARK: - Credentials

    var keyID: String {
        get { UserDefaults.standard.string(forKey: Self.keyIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.keyIDKey); client = nil }
    }

    var teamID: String {
        get { UserDefaults.standard.string(forKey: Self.teamIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.teamIDKey); client = nil }
    }

    var hasKey: Bool { privateKey != nil }

    var isConfigured: Bool { hasKey && !keyID.isEmpty && !teamID.isEmpty }

    /// Registered phones, whether or not they are connected.
    var registeredDeviceCount: Int { tokens.count }

    func storeKey(_ pem: String) {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        client = nil
        lastError = nil
    }

    func forgetKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ] as CFDictionary)
        client = nil
    }

    private var privateKey: String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Devices

    func register(deviceID: String, token: String) {
        var current = tokens
        // A reinstall gives the same device a new token; keying on `deviceID`
        // replaces it instead of accumulating a dead one that Apple will keep
        // rejecting with `Unregistered`.
        current[deviceID] = token
        tokens = current
    }

    func markConnected(_ deviceID: String) { connected.insert(deviceID) }
    func markDisconnected(_ deviceID: String) { connected.remove(deviceID) }

    func forgetAllDevices() {
        UserDefaults.standard.removeObject(forKey: Self.tokensKey)
        connected.removeAll()
    }

    // MARK: - Sending

    /// Pushes to every registered phone that is *not* currently connected.
    func push(_ notice: CardMoveNotice) {
        guard isConfigured else { return }
        let targets = tokens.filter { !connected.contains($0.key) }
        guard !targets.isEmpty else { return }

        guard let client = makeClient() else { return }
        for (deviceID, token) in targets {
            Task { [weak self] in
                do {
                    try await client.send(notice, to: token)
                } catch APNsClient.Failure.rejected(_, let reason)
                    where reason == "Unregistered" || reason == "BadDeviceToken" {
                    // Apple's way of saying this token is dead — the app was
                    // deleted, or the token belongs to the other environment and
                    // both hosts refused it. Keeping it means retrying forever.
                    await self?.drop(deviceID: deviceID, reason: reason)
                } catch {
                    await self?.report(error.localizedDescription)
                }
            }
        }
    }

    private func drop(deviceID: String, reason: String) {
        var current = tokens
        current[deviceID] = nil
        tokens = current
        lastError = "Removed a phone Apple no longer recognises (\(reason))."
    }

    private func report(_ message: String) { lastError = message }

    private func makeClient() -> APNsClient? {
        if let client { return client }
        guard let privateKey else { return nil }
        let made = APNsClient(credentials: .init(
            keyID: keyID,
            teamID: teamID,
            bundleID: Self.phoneBundleID,
            privateKeyPEM: privateKey
        ))
        client = made
        return made
    }
}
