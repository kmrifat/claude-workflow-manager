import Foundation

/// Exposes the local dashboard through a `cloudflared` quick tunnel.
///
/// Outbound only — no port forwarding, nothing listening on the public internet
/// except Cloudflare's edge. The tunnel is a child process; when the host exits,
/// the tunnel goes with it.
///
/// An actor because it owns the child process and the discovered hostname.
public actor TunnelController {
    private var process: Process?
    private var logURL: URL?
    private(set) public var publicURL: URL?

    public init() {}

    public enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case noHostname(logPath: String)

        public var description: String {
            switch self {
            case .notInstalled:
                return "cloudflared is not installed — `brew install cloudflared`"
            case .noHostname(let logPath):
                return "cloudflared started but printed no hostname; see \(logPath)"
            }
        }
    }

    /// Starts the tunnel and waits for the hostname it prints.
    ///
    /// `cloudflared` writes the URL to stderr some seconds after launch, so the
    /// output is captured to a file and polled rather than guessed at.
    @discardableResult
    public func start(port: Int, home: HostPaths, timeout: TimeInterval = 30) async throws -> URL {
        let executable: URL
        do { executable = try ProcessRunner.locate("cloudflared") }
        catch { throw Failure.notInstalled }

        let log = home.root.appending(path: "cloudflared.log")
        try? FileManager.default.removeItem(at: log)

        let child = try ProcessRunner.spawn(
            executable: executable,
            arguments: ["tunnel", "--url", "http://127.0.0.1:\(port)", "--no-autoupdate"],
            standardOutput: log
        )
        process = child
        logURL = log

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = Self.hostname(inLogAt: log) {
                publicURL = url
                return url
            }
            guard child.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(400))
        }

        child.terminate()
        process = nil
        throw Failure.noHostname(logPath: log.path(percentEncoded: false))
    }

    public func stop() {
        process?.terminate()
        process = nil
        publicURL = nil
    }

    /// Pulls the first `https://<something>.trycloudflare.com` out of the log.
    static func hostname(inLogAt url: URL) -> URL? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return hostname(inLog: text)
    }

    static func hostname(inLog text: String) -> URL? {
        // The banner wraps the URL in box-drawing characters, so scan for the
        // scheme and stop at the first character that cannot be in a hostname.
        guard let start = text.range(of: "https://") else { return nil }
        let tail = text[start.lowerBound...]
        let host = tail.prefix { !$0.isWhitespace && $0 != "|" && $0 != "│" }
        guard host.hasSuffix("trycloudflare.com") || host.contains(".") else { return nil }
        return URL(string: String(host))
    }
}
