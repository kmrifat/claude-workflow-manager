//
//  Tailscale.swift
//  workflow-manager
//
//  Whether this Mac is on a tailnet, and as what. Read-only: Pitwall never
//  changes Tailscale's configuration — no `tailscale serve`, no ACLs, no
//  certificates. It only listens on the address Tailscale already gave it,
//  which is why turning remote access off undoes everything.
//
//  Two sources, because neither alone is enough:
//
//  - **The network interfaces** say whether a tailnet address exists, with no
//    process spawned. Tailscale puts it on a `utun` interface, in the CGNAT
//    range 100.64.0.0/10.
//  - **`tailscale status --json`** adds the MagicDNS name ("my-mac.tail1234.ts.net"),
//    which is what a phone should dial — the name survives the address
//    changing. The CLI is optional: the Mac App Store app ships it inside its
//    bundle, Homebrew puts it on the path, and some installs have neither.
//

import Foundation
import Darwin

nonisolated enum Tailscale {
    struct Node: Sendable, Equatable {
        var ipv4: String
        /// MagicDNS name without the trailing dot, when MagicDNS is on.
        var dnsName: String?
        var tailnet: String?

        /// What another device should dial: the name if there is one.
        var preferredHost: String { dnsName ?? ipv4 }

        /// Every spelling a client might put in a `Host` header.
        var hostNames: [String] {
            var names = [ipv4]
            if let dnsName {
                names.append(dnsName)
                if let short = dnsName.split(separator: ".").first { names.append(String(short)) }
            }
            return names
        }
    }

    enum Status: Sendable, Equatable {
        /// No tailnet address and no CLI: Tailscale is not on this Mac.
        case notInstalled
        /// Installed, but not connected — logged out, stopped, or waiting.
        case notConnected(String)
        case connected(Node)

        var node: Node? {
            if case .connected(let node) = self { return node }
            return nil
        }
    }

    /// Where the CLI lives, most specific first. The app bundle's binary is the
    /// CLI when invoked by path — Tailscale documents this for the Mac app.
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static let downloadURL = URL(string: "https://tailscale.com/download/mac")!

    static func locateCLI() -> URL? {
        cliCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    static func status() async -> Status {
        let address = interfaceAddress()
        guard let cli = locateCLI() else {
            return address.map { .connected(Node(ipv4: $0)) } ?? .notInstalled
        }
        do {
            let output = try await CommandRunner.run(executable: cli, arguments: ["status", "--json"], timeout: 8)
            return parse(Data(output.standardOutput.utf8), fallbackAddress: address)
        } catch {
            // `tailscale status` exits non-zero when stopped or logged out —
            // with the reason on stderr, which is exactly what to show.
            if let address { return .connected(Node(ipv4: address)) }
            let reason = (error as? LocalizedError)?.errorDescription ?? "Tailscale is not running."
            return .notConnected(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Parsing

    private struct StatusJSON: Decodable {
        struct Peer: Decodable {
            var DNSName: String?
            var TailscaleIPs: [String]?
        }
        struct Tailnet: Decodable {
            var Name: String?
            var MagicDNSEnabled: Bool?
        }
        var BackendState: String?
        var me: Peer?
        var CurrentTailnet: Tailnet?

        enum CodingKeys: String, CodingKey {
            case BackendState, CurrentTailnet
            case me = "Self"
        }
    }

    /// Pure, so it can be tested against captured output without Tailscale.
    static func parse(_ data: Data, fallbackAddress: String? = nil) -> Status {
        guard let json = try? JSONDecoder().decode(StatusJSON.self, from: data) else {
            return fallbackAddress.map { .connected(Node(ipv4: $0)) }
                ?? .notConnected("Couldn’t read Tailscale’s status.")
        }
        guard json.BackendState == "Running" else {
            return .notConnected(describe(json.BackendState))
        }
        let ipv4 = json.me?.TailscaleIPs?.first { $0.contains(".") } ?? fallbackAddress
        guard let ipv4 else { return .notConnected("Tailscale is running but this Mac has no address yet.") }

        var dnsName = json.me?.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Without MagicDNS the name does not resolve on other devices, and a
        // name that does not resolve is worse than an address that does.
        if json.CurrentTailnet?.MagicDNSEnabled == false || dnsName?.isEmpty == true { dnsName = nil }
        return .connected(Node(ipv4: ipv4, dnsName: dnsName, tailnet: json.CurrentTailnet?.Name))
    }

    private static func describe(_ state: String?) -> String {
        switch state {
        case "NeedsLogin": "Signed out of Tailscale. Open Tailscale and log in."
        case "Stopped": "Tailscale is turned off. Open Tailscale and connect."
        case "NeedsMachineAuth": "This Mac is waiting for approval in your tailnet’s admin console."
        case "Starting": "Tailscale is starting…"
        default: "Tailscale is not connected."
        }
    }

    // MARK: - Interfaces

    /// The IPv4 address Tailscale gave this Mac, if any: on a `utun`
    /// interface and inside 100.64.0.0/10.
    static func interfaceAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("utun")
            else { continue }
            var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let value = UInt32(bigEndian: inet.sin_addr.s_addr)
            guard value & 0xFFC0_0000 == 0x6440_0000 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inet.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buffer)
        }
        return nil
    }
}
