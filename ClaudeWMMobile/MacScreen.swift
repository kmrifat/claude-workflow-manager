//
//  MacScreen.swift
//  ClaudeWMMobile
//
//  Your Mac (M06): which Mac this phone is paired with, every route it can
//  take there and which one it is on, notifications, and pairing again.
//
//  The routes are listed in the order `MainTabs.connect` tries them, so the
//  screen doubles as the explanation of why the phone picked the one it did.
//

import SwiftUI
import ClaudeWMWire

struct MacScreen: View {
    let connection: BoardConnection
    let browser: BoardBrowser
    @Binding var paired: PairedMac?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("cardMoveNotificationsEnabled") private var notifyOnMoves = true
    @AppStorage("claudeFinishedNotificationsEnabled") private var notifyOnFinished = true
    @State private var pairing = false
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill)))
                        Text(paired?.displayName ?? "Your Mac").font(.title3.bold())
                        HStack(spacing: 5) {
                            Circle().fill(connection.state.isConnected ? .green : .orange).frame(width: 7, height: 7)
                            Text(connection.state.isConnected ? "Connected · \(connection.route.title.lowercased())"
                                                              : "Not connected")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    route(.local, symbol: "wifi", colour: .blue, title: "Local network",
                          detail: "Same Wi-Fi as the Mac",
                          available: paired.map { browser.endpoint(named: $0.service) != nil } ?? false,
                          offered: true)
                    route(.tailnet, symbol: "point.3.connected.trianglepath.dotted", colour: .gray, title: "Tailscale",
                          detail: paired?.remoteHost ?? "Not offered by the Mac",
                          available: paired?.remoteHost != nil, offered: paired?.remoteHost != nil)
                    route(.tunnel, symbol: "cloud.fill", colour: .orange, title: "Cloudflare Tunnel",
                          detail: paired?.relayURL.flatMap { URL(string: $0)?.host } ?? "Not offered by the Mac",
                          available: paired?.relayURL != nil, offered: paired?.relayURL != nil,
                          sealed: true)
                } header: {
                    Text("How this phone reaches it")
                } footer: {
                    Text("""
                        Tried in this order. Through Cloudflare everything is sealed with this phone’s \
                        pairing key, so Cloudflare only forwards it.
                        """)
                }

                Section {
                    Toggle("Card moves", isOn: $notifyOnMoves)
                    Toggle("When Claude finishes a card", isOn: $notifyOnFinished)
                } header: {
                    Text("Notifications")
                } footer: {
                    // iOS suspends the app and drops the socket shortly after it
                    // leaves the screen, so this is a real limit rather than a
                    // caveat — better said than discovered.
                    Text("Shown while Pitwall is open or recently used, and pushed by your Mac if it has a push key set up.")
                }
                .onChange(of: notifyOnMoves) { _, _ in PhoneNotifier.shared.prepare() }
                .onChange(of: notifyOnFinished) { _, _ in PhoneNotifier.shared.prepare() }

                Section {
                    Button("Pair Again") { pairing = true }
                    Button("Forget This Mac", role: .destructive) { confirmingForget = true }
                }
            }
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .sheet(isPresented: $pairing) {
                PairingView(browser: browser) { mac in
                    PairedMacStore.save(mac)
                    paired = mac
                    pairing = false
                    dismiss()
                }
            }
            .confirmationDialog("Forget \(paired?.displayName ?? "this Mac")?", isPresented: $confirmingForget,
                                titleVisibility: .visible) {
                Button("Forget This Mac", role: .destructive) {
                    connection.disconnect()
                    PairedMacStore.forget()
                    paired = nil
                }
            } message: {
                Text("You’ll need to scan its code again to see your boards.")
            }
        }
    }

    private func route(_ route: BoardConnection.Route, symbol: String, colour: Color, title: String,
                       detail: String, available: Bool, offered: Bool, sealed: Bool = false) -> some View {
        let inUse = connection.state.isConnected && connection.route == route
        return HStack(spacing: 12) {
            IconTile(symbol: symbol, colour: offered ? colour : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if sealed, offered {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if inUse {
                Text("In use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(.green.opacity(0.15)))
            } else if offered {
                Text(available && route == .local ? "Found" : route == .local ? "Away" : "Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(offered ? 1 : 0.6)
    }
}
