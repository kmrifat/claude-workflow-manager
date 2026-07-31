import Foundation
import Security

/// Where the GitHub token comes from.
///
/// A fine-grained PAT with repo + project scope. The host only ever *reads* it —
/// it never writes, prompts for, or logs a token. Provisioning is the operator's
/// job, documented in CLAUDE.md.
public enum GitHubToken {
    public static let keychainService = "dev.workflowhost"
    public static let keychainAccount = "github-token"
    /// Development fallback, so a scratch instance can run without touching the
    /// login Keychain.
    public static let environmentKey = "WORKFLOWHOST_GITHUB_TOKEN"

    public enum LookupError: Error, CustomStringConvertible, Equatable {
        case notFound
        case keychainFailure(OSStatus)
        case malformed

        public var description: String {
            switch self {
            case .notFound:
                return """
                    no GitHub token found.

                    Store a fine-grained PAT (repo + project scope) in the Keychain:

                      security add-generic-password -U -s \(GitHubToken.keychainService) \
                    -a \(GitHubToken.keychainAccount) -w

                    or, for a scratch instance, export \(GitHubToken.environmentKey).
                    """
            case .keychainFailure(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "could not read the Keychain: \(message) (\(status))"
            case .malformed:
                return "the stored GitHub token is not valid UTF-8"
            }
        }
    }

    /// Environment first, so a scratch run never has to touch — or be prompted
    /// for access to — the login Keychain.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let fromEnvironment = environment[environmentKey], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return try loadFromKeychain()
    }

    static func loadFromKeychain() throws -> String {
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
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else {
                throw LookupError.malformed
            }
            // Keychain values pasted from a terminal often carry a newline.
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            throw LookupError.notFound
        default:
            throw LookupError.keychainFailure(status)
        }
    }
}
