import Foundation
import Testing
@testable import WorkflowCore

@Suite("HostConfig")
struct HostConfigTests {
    /// The exact JSON from the build plan. If this stops decoding, the documented
    /// config format and the code have diverged.
    static let specJSON = """
        {
          "maxConcurrentPerRepo": 2,
          "pollIntervalSec": 60,
          "repos": [
            {
              "owner": "me",
              "name": "product-a",
              "path": "/Users/me/code/product-a",
              "projectNumber": 3,
              "readyColumn": "Ready",
              "activeColumn": "In progress",
              "reviewColumn": "Review"
            }
          ]
        }
        """

    @Test("decodes the documented config format")
    func decodesSpecJSON() throws {
        let config = try JSONDecoder().decode(HostConfig.self, from: Data(Self.specJSON.utf8))

        #expect(config.maxConcurrentPerRepo == 2)
        #expect(config.pollIntervalSec == 60)
        #expect(config.repos.count == 1)

        let repo = try #require(config.repos.first)
        #expect(repo.owner == "me")
        #expect(repo.name == "product-a")
        #expect(repo.path == "/Users/me/code/product-a")
        #expect(repo.projectNumber == 3)
        #expect(repo.readyColumn == "Ready")
        #expect(repo.activeColumn == "In progress")
        #expect(repo.reviewColumn == "Review")
    }

    @Test("repo id is owner/name")
    func repoIdentifier() throws {
        let config = try JSONDecoder().decode(HostConfig.self, from: Data(Self.specJSON.utf8))
        #expect(config.repos.first?.id == "me/product-a")
    }

    @Test("round-trips through encode and decode")
    func roundTrips() throws {
        let original = try JSONDecoder().decode(HostConfig.self, from: Data(Self.specJSON.utf8))
        let reencoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostConfig.self, from: reencoded)
        #expect(decoded == original)
    }

    @Test("run statuses match the runs.status vocabulary")
    func runStatusVocabulary() {
        #expect(Set(RunStatus.allCases.map(\.rawValue))
            == ["queued", "running", "review", "done", "failed"])
    }
}
