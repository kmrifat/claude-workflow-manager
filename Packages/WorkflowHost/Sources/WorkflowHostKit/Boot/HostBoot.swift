import Foundation
import Vapor
import WorkflowCore

/// Boot and command dispatch: resolve paths, load config, open and migrate the
/// database, then do whatever the command asked for.
///
/// The dispatcher arrives in phase 6; nothing here spawns anything.
public enum HostBoot {
    public static let version = "0.3.0"

    /// Everything a command needs, assembled once.
    struct Context {
        let paths: HostPaths
        let config: HostConfig
        let database: AppDatabase
        let migrations: [String]
        var cache: CacheStore { CacheStore(database: database) }
        var runs: RunStore { RunStore(database: database) }
        var git: GitReader { GitReader(cache: cache) }
    }

    public static func run(arguments: [String] = CommandLine.arguments) async throws -> Int32 {
        let command = try HostCommand.parse(arguments)
        if command == .help {
            print(HostCommand.usage)
            return 0
        }

        let context = try openContext()

        switch command {
        case .help:
            return 0  // handled above

        case .boot:
            print(report(
                paths: context.paths,
                config: context.config,
                journalMode: try context.database.journalMode(),
                migrations: context.migrations
            ))
            return 0

        case .poll(let once):
            return try await poll(context, once: once)

        case .ready:
            print(try ReadyCommand.render(config: context.config, cache: context.cache))
            return 0

        case .serve(let port, let tunnel, let dispatch):
            return try await serve(context, port: port, tunnel: tunnel, dispatch: dispatch)
        }
    }

    private static func openContext() throws -> Context {
        let paths = try HostPaths.resolve()
        try paths.createRootIfNeeded()
        Log.boot.info("home \(paths.displayRoot, privacy: .public)")

        let config = try ConfigLoader.load(at: paths.configURL)
        Log.config.info("loaded \(config.repos.count) repo(s)")

        let database = try AppDatabase(paths: paths)
        let migrations = try database.migrate()
        Log.database.info("migrations=\(migrations.count)")

        return Context(paths: paths, config: config, database: database, migrations: migrations)
    }

    private static func poll(_ context: Context, once: Bool) async throws -> Int32 {
        let client = GitHubClient(token: try GitHubToken.load())
        let poller = GitHubPoller(
            config: context.config,
            client: client,
            cache: context.cache
        )

        guard once else {
            // Runs until the process is interrupted.
            await poller.run()
            return 0
        }

        let report = await poller.pollOnce()
        print("polled \(report.outcomes.count) repo(s)")
        print(report.summary)
        // A one-shot poll reports failure so a human notices; the continuous
        // loop deliberately never exits on one.
        return report.hadFailures ? 1 : 0
    }

    /// Polls and serves the dashboard until interrupted.
    private static func serve(
        _ context: Context,
        port: Int,
        tunnel wantsTunnel: Bool,
        dispatch wantsDispatch: Bool
    ) async throws -> Int32 {
        let resolution = try DashboardToken.resolve()
        let hub = EventHub()
        let client = GitHubClient(token: try GitHubToken.load())
        let poller = GitHubPoller(
            config: context.config, client: client, cache: context.cache, hub: hub
        )
        let builder = StateBuilder(
            config: context.config, cache: context.cache,
            runs: context.runs, git: context.git
        )

        var dispatcher: Dispatcher?
        if wantsDispatch {
            // Runs are assigned to whoever `gh` is authenticated as, so the lock
            // is held by a real identity rather than a name we invented.
            let login = try await currentGitHubLogin()
            dispatcher = Dispatcher(
                config: context.config, client: client, cache: context.cache,
                runs: context.runs, state: builder, selfLogin: login, hub: hub
            )
            // Any run still marked running is from a host that died — the Mac
            // slept, or the app was quit. Clear those before starting new work.
            await dispatcher?.reconcile()
        }

        let server = DashboardServer(
            state: builder,
            runs: context.runs,
            hub: hub,
            token: resolution.token,
            controls: dispatcher
        )

        // Explicit arguments — `.detect()` would try to parse our own subcommand
        // off the command line and fail.
        let app = try await Application.make(
            Vapor.Environment(name: "production", arguments: ["WorkflowHost"])
        )
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        app.logger.logLevel = .warning
        try server.register(on: app)

        let local = "http://127.0.0.1:\(port)/?token=\(resolution.token)"
        print("WorkflowHost \(version) — dashboard")
        print("  local   \(local)")
        if resolution.isNew {
            // Printed once, on first run. It lives in the Keychain from now on.
            print("  token   \(resolution.token)   (generated now, stored in the Keychain)")
        }

        let tunnel = TunnelController()
        if wantsTunnel {
            do {
                let url = try await tunnel.start(port: port, home: context.paths)
                print("  remote  \(url.absoluteString)/?token=\(resolution.token)")
            } catch {
                // A tunnel that won't start must not take the local dashboard
                // down with it.
                print("  remote  unavailable — \(error)")
            }
        }
        if let dispatcher {
            print("  dispatch ON — runs will be started, PRs opened, nothing merged")
            _ = dispatcher
        } else {
            print("  dispatch off — pass --dispatch to start runs")
        }
        print("  Ctrl-C to stop.")

        await withTaskGroup(of: Void.self) { group in
            // Vapor installs the signal handlers; `execute()` returns once it
            // has caught SIGINT or SIGTERM.
            group.addTask { try? await app.execute() }
            group.addTask { await poller.run() }

            if let dispatcher {
                group.addTask {
                    // One tick per poll interval, after the poller has had a
                    // chance to refresh the board it selects from.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(context.config.pollIntervalSec))
                        guard !Task.isCancelled else { return }
                        await dispatcher.tick()
                    }
                }
            }

            // Whichever finishes first ends the process. Without this the group
            // waits for the poller, which loops forever — so the daemon would
            // ignore SIGTERM entirely and need `kill -9`.
            await group.next()
            group.cancelAll()
        }

        await tunnel.stop()
        await hub.closeAll()
        try await app.asyncShutdown()
        return 0
    }

    /// Who `gh` is signed in as. Runs are assigned to this login, and the
    /// dispatcher skips anything assigned to anyone — including itself.
    private static func currentGitHubLogin() async throws -> String {
        let gh = try ProcessRunner.locate("gh")
        let output = try await ProcessRunner.run(
            executable: gh,
            arguments: ["api", "user", "--jq", ".login"],
            timeout: 20
        )
        let login = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            throw ProcessRunner.Failure.exited(
                command: "gh api user", code: 0,
                standardError: "could not determine the signed-in GitHub login"
            )
        }
        return login
    }

    static func report(
        paths: HostPaths,
        config: HostConfig,
        journalMode: String,
        migrations: [String]
    ) -> String {
        var lines = [
            "WorkflowHost \(version)",
            "  home        \(paths.displayRoot)",
            "  config      config.json (\(config.repos.count) repo\(config.repos.count == 1 ? "" : "s"))",
            "  database    db.sqlite  journal=\(journalMode)  migrations=[\(migrations.joined(separator: ", "))]",
            "  concurrency \(config.maxConcurrentPerRepo) per repo, poll every \(config.pollIntervalSec)s",
            "  repos",
        ]

        for repo in config.repos {
            lines.append("    \(repo.id)  ->  \(repo.path)")
            lines.append(
                "                      project #\(repo.projectNumber)"
                + "  \(repo.readyColumn) -> \(repo.activeColumn) -> \(repo.reviewColumn)"
            )
        }

        return lines.joined(separator: "\n")
    }
}
