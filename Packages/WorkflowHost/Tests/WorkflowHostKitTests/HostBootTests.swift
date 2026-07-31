import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("HostBoot")
struct HostBootTests {
    @Test("the boot report states everything the checkpoint asks for")
    func reportContents() throws {
        let paths = HostPaths(root: URL(filePath: "/tmp/wfh-example", directoryHint: .isDirectory))
        let config = HostConfig(
            maxConcurrentPerRepo: 2,
            pollIntervalSec: 60,
            repos: [
                RepoConfig(
                    owner: "me", name: "product-a", path: "/Users/me/code/product-a",
                    projectNumber: 3, readyColumn: "Ready",
                    activeColumn: "In progress", reviewColumn: "Review"
                )
            ]
        )

        let report = HostBoot.report(
            paths: paths, config: config,
            journalMode: "wal", migrations: ["v1_initialSchema"]
        )

        #expect(report.contains("WorkflowHost \(HostBoot.version)"))
        #expect(report.contains("/tmp/wfh-example"))
        #expect(report.contains("config.json (1 repo)"))
        #expect(report.contains("journal=wal"))
        #expect(report.contains("migrations=[v1_initialSchema]"))
        #expect(report.contains("2 per repo, poll every 60s"))
        #expect(report.contains("me/product-a  ->  /Users/me/code/product-a"))
        #expect(report.contains("project #3  Ready -> In progress -> Review"))
    }

    /// HostPaths is the only place allowed to know where the host home lives.
    /// Anything else reaching for Application Support directly would make that
    /// subsystem untestable and would ignore WORKFLOWHOST_HOME.
    @Test("only HostPaths knows about Application Support")
    func applicationSupportIsConfinedToHostPaths() throws {
        let sources = URL(filePath: #filePath)                 // …/Tests/WorkflowHostKitTests/this file
            .deletingLastPathComponent()                        // …/WorkflowHostKitTests
            .deletingLastPathComponent()                        // …/Tests
            .deletingLastPathComponent()                        // …/WorkflowHost
            .appending(path: "Sources", directoryHint: .isDirectory)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "source enumeration found nothing — the path above is wrong")

        let offenders = try files
            .filter { $0.lastPathComponent != "HostPaths.swift" }
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("applicationSupportDirectory") }
        #expect(offenders.map(\.lastPathComponent) == [])
    }
}
