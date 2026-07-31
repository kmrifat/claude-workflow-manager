import AppKit
import Foundation
import Observation
import WorkflowCore
import WorkflowHostKit

/// Owns the embedded host and the state the menu renders.
///
/// `@MainActor` because it drives UI. All the host's own work happens off it —
/// the poller is an actor, and the database is GRDB's to serialize.
@MainActor
@Observable
final class HostAppModel {
    enum Phase {
        case starting
        case running(dashboard: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var state: DashboardState?
    private(set) var lastRefresh: Date?

    /// Called when the number of active runs changes, so the status item title
    /// can be updated without the popover being open.
    var onCountChanged: ((Int) -> Void)?

    var activeRunCount: Int { state?.activeRunCount ?? 0 }

    private var runtime: EmbeddedHost?
    private var refreshTask: Task<Void, Never>?

    func start() async {
        do {
            let runtime = try await EmbeddedHost.start()
            self.runtime = runtime
            phase = .running(dashboard: runtime.dashboardURL)
            await refresh()

            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await self?.refresh()
                }
            }
        } catch {
            // A bad config or missing token must show up in the menu rather than
            // leaving a status item that silently does nothing.
            phase = .failed(String(describing: error))
        }
    }

    func refresh() async {
        guard let runtime else { return }
        let snapshot = await runtime.state.build()
        state = snapshot
        lastRefresh = Date()
        onCountChanged?(snapshot.activeRunCount)
    }

    func openDashboard() {
        if case .running(let url) = phase {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        refreshTask?.cancel()
        runtime?.stop()
        runtime = nil
    }
}

/// The host, running inside this process.
///
/// Deliberately thin: it assembles the same pieces the `serve` subcommand does,
/// so there is one implementation of "the host" rather than two that drift.
@MainActor
final class EmbeddedHost {
    let paths: HostPaths
    let config: HostConfig
    let state: StateBuilder
    let dashboardURL: URL

    private let poller: GitHubPoller
    private var pollerTask: Task<Void, Never>?

    private init(
        paths: HostPaths,
        config: HostConfig,
        state: StateBuilder,
        poller: GitHubPoller,
        dashboardURL: URL
    ) {
        self.paths = paths
        self.config = config
        self.state = state
        self.poller = poller
        self.dashboardURL = dashboardURL
    }

    static func start(port: Int = 8420) async throws -> EmbeddedHost {
        let paths = try HostPaths.resolve()
        try paths.createRootIfNeeded()

        let config = try ConfigLoader.load(at: paths.configURL)
        let database = try AppDatabase(paths: paths)
        try database.migrate()

        let cache = CacheStore(database: database)
        let runs = RunStore(database: database)
        let state = StateBuilder(
            config: config, cache: cache, runs: runs, git: GitReader(cache: cache)
        )

        let token = try DashboardToken.resolve().token
        let poller = GitHubPoller(
            config: config,
            client: GitHubClient(token: try GitHubToken.load()),
            cache: cache
        )

        let host = EmbeddedHost(
            paths: paths,
            config: config,
            state: state,
            poller: poller,
            dashboardURL: URL(string: "http://127.0.0.1:\(port)/?token=\(token)")!
        )
        // The menu bar app reads state directly; it does not need the HTTP
        // server for itself. `serve` is still how a phone reaches it.
        host.pollerTask = Task { await poller.run() }
        return host
    }

    func stop() {
        pollerTask?.cancel()
        pollerTask = nil
    }
}
