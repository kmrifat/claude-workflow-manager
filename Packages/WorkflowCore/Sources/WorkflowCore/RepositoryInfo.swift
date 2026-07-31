import Foundation

/// Repository metadata worth caching.
///
/// `defaultBranch` exists because it must not be assumed to be `main` — the git
/// reader in phase 2 and the rebase before opening a PR in phase 6 both read it
/// from here rather than guessing.
public struct RepositoryInfo: Codable, Sendable, Equatable {
    public let owner: String
    public let name: String
    public let defaultBranch: String

    public var id: String { "\(owner)/\(name)" }

    public init(owner: String, name: String, defaultBranch: String) {
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
    }
}
