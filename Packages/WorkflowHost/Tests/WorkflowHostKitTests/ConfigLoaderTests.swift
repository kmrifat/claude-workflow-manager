import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("ConfigLoader")
struct ConfigLoaderTests {
    /// Builds valid config JSON pointing at `repoPath`, optionally dropping a
    /// field or overriding one, so each test changes exactly one thing.
    private func configJSON(
        repoPath: String,
        omitting omitted: String? = nil,
        overrides: [String: String] = [:]
    ) -> String {
        let top: [(String, String)] = [
            ("maxConcurrentPerRepo", "2"),
            ("pollIntervalSec", "60"),
        ]
        let repo: [(String, String)] = [
            ("owner", "\"me\""),
            ("name", "\"product-a\""),
            ("path", "\"\(repoPath)\""),
            ("projectNumber", "3"),
            ("readyColumn", "\"Ready\""),
            ("activeColumn", "\"In progress\""),
            ("reviewColumn", "\"Review\""),
        ]

        func render(_ fields: [(String, String)]) -> String {
            fields
                .filter { $0.0 != omitted }
                .map { "\"\($0.0)\": \(overrides[$0.0] ?? $0.1)" }
                .joined(separator: ", ")
        }

        return "{ \(render(top)), \"repos\": [ { \(render(repo)) } ] }"
    }

    @Test("loads a valid config")
    func loadsValidConfig() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(configJSON(repoPath: repoPath))

        let config = try ConfigLoader.load(at: home.paths.configURL)
        #expect(config.maxConcurrentPerRepo == 2)
        #expect(config.repos.map(\.id) == ["me/product-a"])
    }

    @Test("a missing nested field is reported with its full path")
    func missingNestedFieldNamesTheField() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(configJSON(repoPath: repoPath, omitting: "owner"))

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        // Guards the keyNotFound coding-path fix: without appending the missing
        // key this reports `repos[0]` and the operator has to go hunting.
        #expect(error?.description.contains("repos[0].owner") == true)
        #expect(error?.description.contains("required field is missing") == true)
    }

    @Test("a missing top-level field is reported by name")
    func missingTopLevelField() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(configJSON(repoPath: repoPath, omitting: "pollIntervalSec"))

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("config.json:pollIntervalSec") == true)
    }

    @Test("a wrongly typed field names the field")
    func wrongTypeNamesTheField() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(
            configJSON(repoPath: repoPath, overrides: ["maxConcurrentPerRepo": "\"two\""])
        )

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("maxConcurrentPerRepo") == true)
        #expect(error?.description.contains("expected Int") == true)
    }

    @Test("a null field is distinguished from a missing one")
    func nullFieldIsItsOwnCase() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(configJSON(repoPath: repoPath, overrides: ["path": "null"]))

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("repos[0].path") == true)
        #expect(error?.description.contains("value is null") == true)
    }

    @Test("truncated JSON is reported as malformed, not as a field error")
    func truncatedJSON() throws {
        let home = try TempHome()
        try home.writeConfig("{ \"maxConcurrentPerRepo\": 2, \"repos\": [")

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        guard case .malformedJSON = error else {
            Issue.record("expected .malformedJSON, got \(String(describing: error))")
            return
        }
    }

    @Test("an absent config file fails with a template and exit code 78")
    func absentFile() throws {
        let home = try TempHome()

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        guard case .fileMissing = error else {
            Issue.record("expected .fileMissing, got \(String(describing: error))")
            return
        }
        #expect(error?.exitCode == 78)
        // The message has to be actionable, not just accurate.
        #expect(error?.description.contains("\"maxConcurrentPerRepo\"") == true)
        #expect(error?.description.contains("\"reviewColumn\"") == true)
        // Loading must not create the file it complained about.
        #expect(!FileManager.default.fileExists(atPath: home.paths.configURL.path(percentEncoded: false)))
    }

    @Test("semantic failures use the same field-path notation as decoding failures",
          arguments: [
            ("maxConcurrentPerRepo", "0", "maxConcurrentPerRepo"),
            ("pollIntervalSec", "1", "pollIntervalSec"),
            ("projectNumber", "0", "repos[0].projectNumber"),
            ("owner", "\"\"", "repos[0].owner"),
            ("name", "\"me/product-a\"", "repos[0].name"),
            ("reviewColumn", "\"Ready\"", "repos[0].reviewColumn"),
          ])
    func semanticValidation(field: String, value: String, expectedPath: String) throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig(configJSON(repoPath: repoPath, overrides: [field: value]))

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("config.json:\(expectedPath)") == true)
    }

    @Test("a repo path that is not a git clone is rejected")
    func repoPathMustBeAGitClone() throws {
        let home = try TempHome()
        let notARepo = home.paths.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        try home.writeConfig(configJSON(repoPath: notARepo.path(percentEncoded: false)))

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("repos[0].path") == true)
        #expect(error?.description.contains("not a git repository") == true)
    }

    @Test("two repos declaring the same clone are rejected")
    func duplicatePathsRejected() throws {
        let home = try TempHome()
        let repoPath = try home.makeRepoDirectory(named: "product-a")
        try home.writeConfig("""
            { "maxConcurrentPerRepo": 2, "pollIntervalSec": 60, "repos": [
              { "owner": "me", "name": "a", "path": "\(repoPath)", "projectNumber": 1,
                "readyColumn": "R", "activeColumn": "A", "reviewColumn": "V" },
              { "owner": "me", "name": "b", "path": "\(repoPath)", "projectNumber": 2,
                "readyColumn": "R", "activeColumn": "A", "reviewColumn": "V" }
            ] }
            """)

        let error = #expect(throws: ConfigError.self) {
            try ConfigLoader.load(at: home.paths.configURL)
        }
        #expect(error?.description.contains("repos[1].path") == true)
        #expect(error?.description.contains("duplicate") == true)
    }
}
