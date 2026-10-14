//
//  TailnetAccess.swift
//  workflow-manager
//
//  "Use Pitwall away from home", over Tailscale (the owner's choice over a
//  relay: device to device, nothing of ours in between, and no backend to run).
//
//  Off by default, like every other listening socket in this app. When on and
//  Tailscale is connected, two things become reachable on this Mac's tailnet
//  address, each behind its own switch:
//
//  - **the MCP server**, so Claude Code on another Mac can work these boards —
//    still behind its bearer token;
//  - **Phone Access**, on a fixed port and named in the pairing code, so a
//    phone off the Wi-Fi dials the tailnet name when Bonjour cannot find the
//    Mac — still behind its TLS pre-shared key.
//
//  Being on the tailnet is never enough by itself: a shared node or a guest
//  device is on it too. Each service keeps the credential it already had.
//
//  Tailscale's state is polled rather than observed — it has no notification
//  API a sandbox-free app can subscribe to — every 30 s while this is on, and
//  on demand when Settings opens.
//

import Foundation
import Observation

@MainActor
@Observable
final class TailnetAccess {
    static let shared = TailnetAccess()

    /// Fixed so a phone can be told it in the pairing code. Bonjour finds the
    /// LAN port by itself; off the LAN there is nothing to ask.
    static let phonePort: UInt16 = 7421

    private static let enabledKey = "tailnetAccessEnabled"
    private static let mcpKey = "tailnetExposesMCP"
    private static let phoneKey = "tailnetExposesPhone"

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: TailnetAccess.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { startMonitoring() } else { stopMonitoring() }
            onChange?()
        }
    }

    var exposesMCP: Bool = UserDefaults.standard.object(forKey: TailnetAccess.mcpKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(exposesMCP, forKey: Self.mcpKey)
            onChange?()
        }
    }

    var exposesPhone: Bool = UserDefaults.standard.object(forKey: TailnetAccess.phoneKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(exposesPhone, forKey: Self.phoneKey)
            onChange?()
        }
    }

    private(set) var status: Tailscale.Status?
    private(set) var isChecking = false
    private(set) var lastChecked: Date?

    /// Told whenever what should be listening changes. The owner of the
    /// servers re-applies — this type knows nothing about sockets.
    var onChange: (() -> Void)?

    private var monitor: Task<Void, Never>?

    private init() {}

    /// The node remote clients should reach: on, and connected.
    var node: Tailscale.Node? { isEnabled ? status?.node : nil }
    var mcpNode: Tailscale.Node? { exposesMCP ? node : nil }
    var phoneNode: Tailscale.Node? { exposesPhone ? node : nil }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        var latest = await Tailscale.status()
        #if DEBUG
        // `-FakeTailnetIP <address>` stands in for a tailnet on a Mac without
        // Tailscale, so the remote listeners can be exercised. Point it at
        // `::1` to keep the test off every real network.
        if let fake = UserDefaults.standard.string(forKey: "FakeTailnetIP") {
            latest = .connected(Tailscale.Node(ipv4: fake, dnsName: "test-mac.tail-test.ts.net", tailnet: "test"))
        }
        #endif
        isChecking = false
        lastChecked = .now
        guard latest != status else { return }
        status = latest
        onChange?()
    }

    /// Starts polling if remote access is on. Safe to call repeatedly.
    func startMonitoring() {
        guard isEnabled, monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }
}
