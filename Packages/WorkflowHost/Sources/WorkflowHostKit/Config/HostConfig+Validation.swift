import Foundation
import WorkflowCore

extension HostConfig {
    /// Semantic checks `Codable` cannot express.
    ///
    /// Reports through the same `path` notation the decoder uses, so a bad value
    /// and a missing field read identically to the operator.
    func validated(source url: URL) throws -> HostConfig {
        guard maxConcurrentPerRepo >= 1 else {
            throw ConfigError.invalidValue(
                url, path: "maxConcurrentPerRepo",
                reason: "must be at least 1, got \(maxConcurrentPerRepo)"
            )
        }

        guard pollIntervalSec >= 5 else {
            throw ConfigError.invalidValue(
                url, path: "pollIntervalSec",
                reason: "must be at least 5 seconds, got \(pollIntervalSec)"
            )
        }

        guard !repos.isEmpty else {
            throw ConfigError.invalidValue(
                url, path: "repos", reason: "must list at least one repository"
            )
        }

        var seenIdentifiers: [String: Int] = [:]
        var seenPaths: [String: Int] = [:]

        for (index, repo) in repos.enumerated() {
            try repo.validate(source: url, path: "repos[\(index)]")

            if let first = seenIdentifiers[repo.id] {
                throw ConfigError.invalidValue(
                    url, path: "repos[\(index)]",
                    reason: "duplicate repository \(repo.id), already declared at repos[\(first)]"
                )
            }
            seenIdentifiers[repo.id] = index

            if let first = seenPaths[repo.path] {
                throw ConfigError.invalidValue(
                    url, path: "repos[\(index)].path",
                    reason: "duplicate path, already used by repos[\(first)]"
                )
            }
            seenPaths[repo.path] = index
        }

        return self
    }
}

extension RepoConfig {
    fileprivate func validate(source url: URL, path prefix: String) throws {
        func reject(_ field: String, _ reason: String) -> ConfigError {
            .invalidValue(url, path: "\(prefix).\(field)", reason: reason)
        }

        for (field, value) in [("owner", owner), ("name", name)] {
            guard !value.isEmpty else { throw reject(field, "must not be empty") }
            guard !value.contains("/") else {
                throw reject(field, "must not contain '/' — got \"\(value)\"")
            }
        }

        guard projectNumber > 0 else {
            throw reject("projectNumber", "must be a positive project number, got \(projectNumber)")
        }

        let columns = [
            ("readyColumn", readyColumn),
            ("activeColumn", activeColumn),
            ("reviewColumn", reviewColumn),
        ]
        for (field, value) in columns where value.isEmpty {
            throw reject(field, "must not be empty")
        }
        for (offset, (field, value)) in columns.enumerated() {
            if let clash = columns.prefix(offset).first(where: { $0.1 == value }) {
                throw reject(field, "must differ from \(clash.0) — both are \"\(value)\"")
            }
        }

        // Checking the clone up front catches the most common misconfiguration,
        // and costs one stat call per repo at boot.
        guard self.path.hasPrefix("/") else {
            throw reject("path", "must be an absolute path, got \"\(self.path)\"")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.path, isDirectory: &isDirectory) else {
            throw reject("path", "no such directory: \(self.path)")
        }
        guard isDirectory.boolValue else {
            throw reject("path", "is not a directory: \(self.path)")
        }
        let gitPath = URL(filePath: self.path).appending(path: ".git").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw reject("path", "is not a git repository (no .git): \(self.path)")
        }
    }
}
