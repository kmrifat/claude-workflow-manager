import Foundation
import Testing
import WorkflowCore
@testable import WorkflowHostKit

@Suite("ready command")
struct ReadyCommandTests {
    private func board(readyItems: [(Int, String, [String])]) -> ProjectSnapshot {
        ProjectSnapshot(
            projectId: "PVT_1", number: 3, title: "Product A",
            statusField: ProjectStatusField(id: "F", name: "Status", options: [
                ProjectStatusOption(id: "r", name: "Ready"),
                ProjectStatusOption(id: "a", name: "In progress"),
            ]),
            items: readyItems.map { number, title, assignees in
                ProjectItem(id: "PVTI_\(number)", status: "Ready", content: ProjectItemContent(
                    kind: .issue, number: number, title: title,
                    url: URL(string: "https://github.com/me/product-a/issues/\(number)")!,
                    state: "OPEN", assignees: assignees
                ))
            }
        )
    }

    @Test("prints the Ready column from cache, with its age")
    func printsReadyColumn() throws {
        let fixture = try Fixture()
        let config = fixture.config(repos: [try fixture.repo()])
        let cache = fixture.cache
        try cache.write(
            CacheStore.Key.project(config.repos[0]),
            value: board(readyItems: [(7, "Add API", []), (9, "Fix layout", ["kmrifat"])]),
            etag: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let output = try ReadyCommand.render(
            config: config, cache: cache,
            now: Date(timeIntervalSince1970: 1_700_000_120)
        )

        #expect(output.contains("me/product-a"))
        #expect(output.contains("Ready (2)"))
        #expect(output.contains("#7  Add API"))
        #expect(output.contains("#9  Fix layout"))
        // Assignment is the cross-machine lock, so a claim has to be visible.
        #expect(output.contains("[claimed by kmrifat]"))
        #expect(output.contains("cached 2m ago"))
    }

    /// The phase 1 checkpoint: this command reads the cache the poller wrote,
    /// never GitHub. With a cold cache it must say so rather than fetch.
    @Test("a cold cache says to run the poller instead of calling GitHub")
    func coldCache() throws {
        let fixture = try Fixture()
        let config = fixture.config(repos: [try fixture.repo()])

        let output = try ReadyCommand.render(config: config, cache: fixture.cache)

        #expect(output.contains("no cached board"))
        #expect(output.contains("WorkflowHost poll --once"))
    }

    @Test("an empty Ready column is distinguished from a misnamed one")
    func emptyVersusMisnamed() throws {
        let fixture = try Fixture()
        let config = fixture.config(repos: [try fixture.repo()])
        let cache = fixture.cache
        try cache.write(
            CacheStore.Key.project(config.repos[0]),
            value: board(readyItems: []), etag: nil, at: Date()
        )
        #expect(try ReadyCommand.render(config: config, cache: cache).contains("Ready is empty"))

        // Same board, but the config names a column the board does not have —
        // which would otherwise look identical to an empty column.
        let misconfigured = HostConfig(
            maxConcurrentPerRepo: 2, pollIntervalSec: 60,
            repos: [RepoConfig(
                owner: "me", name: "product-a", path: config.repos[0].path,
                projectNumber: 3, readyColumn: "Todo",
                activeColumn: "In progress", reviewColumn: "Review"
            )]
        )
        let output = try ReadyCommand.render(config: misconfigured, cache: cache)
        #expect(output.contains("no column named \"Todo\""))
        #expect(output.contains("Ready, In progress"))
    }

    @Test("age is rendered in the largest sensible unit")
    func ageFormatting() {
        #expect(ReadyCommand.describe(45) == "45s")
        #expect(ReadyCommand.describe(120) == "2m")
        #expect(ReadyCommand.describe(7_200) == "2h")
        #expect(ReadyCommand.describe(172_800) == "2d")
    }
}

@Suite("command line")
struct HostCommandTests {
    @Test("no arguments boots")
    func defaultsToBoot() throws {
        #expect(try HostCommand.parse(["WorkflowHost"]) == .boot)
    }

    @Test("subcommands parse")
    func subcommands() throws {
        #expect(try HostCommand.parse(["x", "poll"]) == .poll(once: false))
        #expect(try HostCommand.parse(["x", "poll", "--once"]) == .poll(once: true))
        #expect(try HostCommand.parse(["x", "ready"]) == .ready)
        #expect(try HostCommand.parse(["x", "--help"]) == .help)
    }

    @Test("unknown input is rejected with usage")
    func rejectsUnknown() throws {
        let command = #expect(throws: HostCommand.ParseError.self) {
            try HostCommand.parse(["x", "dispatch"])
        }
        #expect(command?.description.contains("unknown command \"dispatch\"") == true)
        #expect(command?.description.contains("Usage:") == true)

        let option = #expect(throws: HostCommand.ParseError.self) {
            try HostCommand.parse(["x", "poll", "--forever"])
        }
        #expect(option?.description.contains("--forever") == true)
    }
}

@Suite("GitHub token")
struct GitHubTokenTests {
    @Test("the environment fallback wins, so a scratch run never touches the Keychain")
    func environmentFallback() throws {
        let token = try GitHubToken.load(environment: ["WORKFLOWHOST_GITHUB_TOKEN": "ghp_test"])
        #expect(token == "ghp_test")
    }

    @Test("an empty environment value is ignored rather than used as a token")
    func emptyEnvironmentValueIgnored() throws {
        // Falls through to the Keychain, which in a test environment has no item.
        // Either outcome is fine; what must not happen is returning "".
        let token = try? GitHubToken.load(environment: ["WORKFLOWHOST_GITHUB_TOKEN": ""])
        #expect(token != "")
    }

    @Test("a missing token explains how to provision one")
    func lookupErrorIsActionable() {
        let message = GitHubToken.LookupError.notFound.description
        #expect(message.contains("security add-generic-password"))
        #expect(message.contains("dev.workflowhost"))
        #expect(message.contains("WORKFLOWHOST_GITHUB_TOKEN"))
    }
}
