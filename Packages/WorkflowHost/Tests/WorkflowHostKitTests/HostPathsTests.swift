import Foundation
import Testing
@testable import WorkflowHostKit

@Suite("HostPaths")
struct HostPathsTests {
    @Test("WORKFLOWHOST_HOME overrides the default location")
    func honoursOverride() throws {
        let paths = try HostPaths.resolve(environment: ["WORKFLOWHOST_HOME": "/tmp/wfh-example"])

        // root is a directory URL, so its path carries a trailing slash; callers
        // use the derived file URLs, and displays use displayRoot.
        #expect(paths.root.path(percentEncoded: false) == "/tmp/wfh-example/")
        #expect(paths.displayRoot == "/tmp/wfh-example")
        #expect(paths.configURL.path(percentEncoded: false) == "/tmp/wfh-example/config.json")
        #expect(paths.databaseURL.path(percentEncoded: false) == "/tmp/wfh-example/db.sqlite")
    }

    @Test("an empty override is ignored")
    func emptyOverrideIgnored() throws {
        let paths = try HostPaths.resolve(environment: ["WORKFLOWHOST_HOME": ""])
        #expect(paths.root.path(percentEncoded: false).hasSuffix("/WorkflowHost"))
    }

    @Test("falls back to Application Support")
    func fallsBackToApplicationSupport() throws {
        // Asserted on the string; nothing is created under the real home.
        let paths = try HostPaths.resolve(environment: [:])
        let root = paths.root.path(percentEncoded: false)

        #expect(root.hasSuffix("/Application Support/WorkflowHost"))
        #expect(paths.databaseURL.path(percentEncoded: false).hasSuffix("/WorkflowHost/db.sqlite"))
    }

    @Test("sidecars accompany the database so a reset can remove all three")
    func sidecars() {
        let paths = HostPaths(root: URL(filePath: "/tmp/wfh-example", directoryHint: .isDirectory))
        #expect(paths.databaseSidecarURLs.map(\.lastPathComponent)
            == ["db.sqlite-wal", "db.sqlite-shm"])
    }

    @Test("createRootIfNeeded makes the directory but never a config file")
    func createsDirectoryOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wfh-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let paths = HostPaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.createRootIfNeeded()
        try paths.createRootIfNeeded()  // idempotent

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(
            atPath: paths.configURL.path(percentEncoded: false)))
    }
}
