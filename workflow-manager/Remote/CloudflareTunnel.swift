//
//  CloudflareTunnel.swift
//  workflow-manager
//
//  The second way to use Pitwall away from home: a Cloudflare Tunnel, run by
//  `cloudflared`. The owner asked for it beside Tailscale, for when the phone or
//  the other Mac cannot run Tailscale.
//
//  It is a different trust model, and the code is shaped by that. Tailscale is
//  device to device and encrypted end to end; a Cloudflare Tunnel terminates
//  TLS at Cloudflare's edge, which forwards to `cloudflared` on this Mac. So:
//
//  - **Phone Access is sealed end to end anyway** (`SealedChannel`): the phone
//    encrypts every message with the pairing key, and Cloudflare forwards
//    ciphertext. A peer without the key fails on its first message.
//  - **The MCP server is not.** It is plain HTTP behind its bearer token, so
//    Cloudflare can read its traffic — board contents and the token. Settings
//    says so where the switch is.
//
//  Two modes:
//
//  - **Quick** — `cloudflared tunnel --url`. No account, a random
//    `*.trycloudflare.com` address that changes every start, and no uptime
//    promise from Cloudflare. The phone learns a new address in `welcome`
//    whenever it connects at home.
//  - **Your domain** — a tunnel created in Cloudflare's dashboard, run with its
//    token. A fixed hostname. The dashboard's public hostname points at
//    `http://localhost:7423`, the gateway (`TunnelGateway`), which sends `/mcp`
//    to the MCP server and `/board` to Phone Access.
//
//  The token is a credential: it lives in the Keychain and reaches `cloudflared`
//  as `TUNNEL_TOKEN` in its environment, never as an argument `ps` would show.
//  Pitwall creates nothing in the Cloudflare account — no tunnels, no DNS
//  records — so switching this off undoes everything it did.
//
//  A tunnel that dies is started again, after a wait that doubles each time
//  (`TunnelRetry`). It used to be started again at once: every failure reaches
//  `onChange`, whose owner calls `start()`, so a quick tunnel Cloudflare refused
//  was re-requested every two seconds — which is exactly what keeps Cloudflare
//  refusing (429, error 1015). A scheduled retry now holds `start()` off until
//  it is due; switching the tunnel off, or changing its settings, clears it.
//

import Foundation
import AppKit
import Observation
import Security

@MainActor
@Observable
final class CloudflareTunnel {
    static let shared = CloudflareTunnel()

    enum Mode: String, CaseIterable, Identifiable {
        case quick
        case named
        var id: String { rawValue }
    }

    enum State: Equatable {
        case stopped
        case notInstalled
        /// Your-domain mode with no token or no hostname yet.
        case needsSetup
        case starting
        case running(URL)
        case failed(String)

        var url: URL? { if case .running(let url) = self { url } else { nil } }
    }

    private static let modeKey = "cloudflareMode"
    private static let hostnameKey = "cloudflareHostname"
    private static let pidKey = "cloudflaredPID"

    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: CloudflareTunnel.modeKey) ?? "") ?? .quick {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if isWanted { restart() }
        }
    }

    /// The public hostname the dashboard routes to this Mac. Your-domain mode
    /// only; Cloudflare does not tell `cloudflared` which hostnames point at it.
    var hostname: String = UserDefaults.standard.string(forKey: CloudflareTunnel.hostnameKey) ?? "" {
        didSet {
            let cleaned = Self.clean(hostname)
            if cleaned != hostname { hostname = cleaned; return }
            UserDefaults.standard.set(hostname, forKey: Self.hostnameKey)
            if isWanted, mode == .named { restart() }
        }
    }

    private(set) var state: State = .stopped
    private(set) var hasToken: Bool = CloudflareTunnelToken.load() != nil

    /// Told when the address changes or the tunnel stops. The owner of the
    /// servers re-applies — this type knows nothing about them.
    var onChange: (() -> Void)?

    private var process: Process?
    private var watcher: Task<Void, Never>?
    private var isWanted = false
    /// The next attempt after a failure, and how many failed in a row.
    private var retry: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// When the next attempt is due, for Settings.
    private(set) var retryAt: Date?
    private let logURL = FileManager.default.temporaryDirectory
        .appending(path: "Pitwall", directoryHint: .isDirectory)
        .appending(path: "cloudflared.log")

    private init() {
        // Quitting Pitwall takes the tunnel down with it: a `cloudflared` left
        // running would keep this Mac reachable with nobody watching.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CloudflareTunnel.shared.stop() }
        }
    }

    var isInstalled: Bool { (try? CommandRunner.locate("cloudflared")) != nil }

    // MARK: - Token

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CloudflareTunnelToken.store(Self.token(fromPasted: trimmed))
        hasToken = true
        if isWanted, mode == .named { restart() }
    }

    func clearToken() {
        CloudflareTunnelToken.delete()
        hasToken = false
        if mode == .named { stop(keepWanted: true) ; state = .needsSetup }
    }

    /// The dashboard offers the token inside a whole install command
    /// (`cloudflared service install eyJ…`). Accept that too and keep the token.
    static func token(fromPasted text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map(String.init).last { $0.count > 40 } ?? text
    }

    static func clean(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    // MARK: - Lifecycle

    /// Starts if it is not running. Safe to call repeatedly — and called after
    /// every change, failures included, so a retry already scheduled is left
    /// to run at its time rather than jumped.
    func start() {
        isWanted = true
        switch state {
        case .starting, .running: return
        default: break
        }
        guard retry == nil else { return }
        launch()
    }

    private func launch() {
        guard let executable = try? CommandRunner.locate("cloudflared") else {
            state = .notInstalled
            return
        }
        var environment: [String: String] = [:]
        var arguments = ["tunnel", "--no-autoupdate"]
        switch mode {
        case .quick:
            arguments += ["--url", "http://127.0.0.1:\(TunnelGateway.port)"]
        case .named:
            guard let token = CloudflareTunnelToken.load(), !hostname.isEmpty else {
                state = .needsSetup
                return
            }
            arguments += ["run"]
            environment["TUNNEL_TOKEN"] = token
        }

        Self.killStale()
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let process: Process
        do {
            process = try CommandRunner.spawn(executable: executable, arguments: arguments,
                                              standardOutput: logURL, environment: environment)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        UserDefaults.standard.set(Int(process.processIdentifier), forKey: Self.pidKey)
        state = .starting
        onChange?()
        watch(process)
    }

    func stop() { stop(keepWanted: false) }

    private func stop(keepWanted: Bool) {
        isWanted = keepWanted
        watcher?.cancel()
        watcher = nil
        // Off, or set up differently: whatever was failing is not what runs
        // next, so the wait starts over.
        retry?.cancel()
        retry = nil
        retryAt = nil
        consecutiveFailures = 0
        if let process, process.isRunning { process.terminate() }
        process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        let wasUp = state.url != nil
        state = .stopped
        if wasUp { onChange?() }
    }

    private func restart() {
        stop(keepWanted: true)
        start()
    }

    /// Reads the log until the tunnel says where it is, then keeps an eye on
    /// the process. `cloudflared` reports everything on stderr, in prose; the
    /// three lines that matter are matched in `CloudflaredLog`.
    private func watch(_ process: Process) {
        let mode = mode
        let hostname = hostname
        let logURL = logURL
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

                if !process.isRunning {
                    self.process = nil
                    let reason = CloudflaredLog.failure(in: log) ?? "cloudflared stopped (exit \(process.terminationStatus))."
                    // Scheduled before `onChange`, whose owner calls `start()`:
                    // that call must find the retry and wait for it.
                    let due = self.scheduleRetry(rateLimited: TunnelRetry.isRateLimited(log))
                    self.state = .failed("\(reason) Trying again at \(due.formatted(date: .omitted, time: .shortened)).")
                    self.onChange?()
                    return
                }
                guard case .starting = self.state else { continue }
                switch mode {
                case .quick:
                    if let url = CloudflaredLog.quickTunnelURL(in: log) {
                        self.consecutiveFailures = 0
                        self.state = .running(url)
                        self.onChange?()
                    }
                case .named:
                    if CloudflaredLog.isConnected(log), let url = URL(string: "https://\(hostname)") {
                        self.consecutiveFailures = 0
                        self.state = .running(url)
                        self.onChange?()
                    }
                }
            }
        }
    }

    /// Starts the tunnel again after the wait `TunnelRetry` gives, and returns
    /// when.
    private func scheduleRetry(rateLimited: Bool) -> Date {
        consecutiveFailures += 1
        let delay = TunnelRetry.delay(afterFailures: consecutiveFailures, rateLimited: rateLimited)
        let due = Date.now.addingTimeInterval(delay)
        retryAt = due
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            self.retryAt = nil
            if self.isWanted { self.launch() }
        }
        return due
    }

    /// A `cloudflared` from a Pitwall that crashed or was force-quit is still
    /// running and still forwarding. Ended before a new one starts — but only
    /// if that pid really is `cloudflared`, since pids are reused.
    private static func killStale() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: pidKey))
        guard pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("/cloudflared") {
            kill(pid, SIGTERM)
        }
        UserDefaults.standard.removeObject(forKey: pidKey)
    }
}

// MARK: - Retrying

/// How long to wait before starting a failed tunnel again. Pure, so it can be
/// checked without a tunnel.
enum TunnelRetry {
    /// Doubling from 10 seconds to 10 minutes. When Cloudflare said "too many
    /// requests", from 2 minutes to 30: asking again soon is what keeps the
    /// limit in force.
    static func delay(afterFailures failures: Int, rateLimited: Bool) -> TimeInterval {
        let base: TimeInterval = rateLimited ? 120 : 10
        let cap: TimeInterval = rateLimited ? 1800 : 600
        return min(cap, base * pow(2, Double(min(max(0, failures - 1), 16))))
    }

    /// Cloudflare's rate limit, as `cloudflared` reports it: an HTTP 429, or
    /// Cloudflare's own error 1015.
    static func isRateLimited(_ log: String) -> Bool {
        log.contains("429") || log.contains("error code: 1015")
            || log.localizedCaseInsensitiveContains("too many requests")
    }
}

// MARK: - Log

/// What `cloudflared` says, read out of its log. Pure, so it can be checked
/// against real output.
enum CloudflaredLog {
    private static let quickURL = try! NSRegularExpression(pattern: "https://[a-z0-9-]+\\.trycloudflare\\.com")

    static func quickTunnelURL(in log: String) -> URL? {
        let range = NSRange(log.startIndex..., in: log)
        guard let match = quickURL.firstMatch(in: log, range: range),
              let swiftRange = Range(match.range, in: log) else { return nil }
        // `api.trycloudflare.com` appears in error lines; it is not a tunnel.
        let found = String(log[swiftRange])
        return found.hasPrefix("https://api.") ? nil : URL(string: found)
    }

    /// A named tunnel is up once one connection to Cloudflare's edge registers.
    static func isConnected(_ log: String) -> Bool {
        log.contains("Registered tunnel connection")
    }

    /// The last error line, without its timestamp and level, for a person.
    static func failure(in log: String) -> String? {
        let errors = log.split(separator: "\n").filter { $0.contains(" ERR ") || $0.contains("error=") }
        guard let last = errors.last else { return nil }
        if let range = last.range(of: " ERR ") { return String(last[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return String(last)
    }
}

// MARK: - Token storage

private enum CloudflareTunnelToken {
    private static let service = "com.binarycastle.workflow-manager.cloudflare"
    private static let account = "tunnel-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ token: String) {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
