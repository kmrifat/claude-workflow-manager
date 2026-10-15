//
//  ClaudeWMMobileApp.swift
//  ClaudeWMMobile
//
//  Pitwall's phone client. Reaches the Mac over the local network only —
//  there is no account, no server, and nothing leaves the Wi-Fi.
//

import SwiftUI

@main
struct ClaudeWMMobileApp: App {
    @State private var connection = BoardConnection()
    @State private var browser = BoardBrowser()
    @State private var paired = PairedMacStore.load()

    /// Only here for the two remote-notification callbacks SwiftUI does not
    /// surface. See `PushAppDelegate`.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(connection: connection, browser: browser, paired: $paired)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // iOS tears sockets down in the background, so coming
                        // forward always means reconnecting. Waiting out a
                        // backoff the user cannot see reads as a broken app.
                        browser.start()
                        connection.reconnectNow()
                        // Cheap, and the token can change under you at any time.
                        PushRegistration.shared.register()
                    case .background:
                        browser.stop()
                    default:
                        break
                    }
                }
                // The Mac's QR code is a `claudewm://pair` URL, so the camera
                // app can hand it straight here without a scanner of our own.
                .onOpenURL { url in
                    if let pairing = try? BoardPairingCode.payload(from: url) {
                        let mac = PairedMac(payload: pairing)
                        PairedMacStore.save(mac)
                        paired = mac
                    }
                }
        }
    }
}

struct RootView: View {
    let connection: BoardConnection
    let browser: BoardBrowser
    @Binding var paired: PairedMac?

    var body: some View {
        Group {
            if paired == nil {
                PairingView(browser: browser) { mac in
                    PairedMacStore.save(mac)
                    paired = mac
                }
            } else {
                MainTabs(connection: connection, browser: browser, paired: $paired)
            }
        }
        .task { browser.start() }
    }
}

/// Where the phone is: which tab, and which card is open over it. Shared so
/// Home can open a card from another board, or send you to the Board tab.
@MainActor
@Observable
final class PhoneNavigation {
    enum Tab: Hashable { case home, board, terminal, files }

    struct CardRef: Identifiable, Hashable {
        var projectID: String
        var cardID: String
        var id: String { cardID }
    }

    var tab: Tab = .home
    var card: CardRef?

    func open(_ cardID: String, in projectID: String) {
        card = CardRef(projectID: projectID, cardID: cardID)
    }
}

/// Home, Board, Terminal and Files.
///
/// A tab bar rather than pushes from the board, because these are places
/// rather than details of one — and because the board's columns are already a
/// horizontal pager, so a swipe between sections would fight it.
///
/// Terminal and Files are always present, never hidden when the Mac has them
/// switched off: a tab that vanishes is indistinguishable from a feature that
/// does not exist, and the screen behind it can say which it is.
struct MainTabs: View {
    let connection: BoardConnection
    let browser: BoardBrowser
    @Binding var paired: PairedMac?

    @State private var navigation = PhoneNavigation()

    var body: some View {
        TabView(selection: $navigation.tab) {
            HomeScreen(connection: connection, navigation: navigation, paired: $paired, browser: browser,
                       reconnect: connect)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(PhoneNavigation.Tab.home)
            BoardScreen(connection: connection, navigation: navigation, paired: paired, reconnect: connect)
                .tabItem { Label("Board", systemImage: "rectangle.split.3x1") }
                .tag(PhoneNavigation.Tab.board)
            TerminalScreen(connection: connection)
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                .tag(PhoneNavigation.Tab.terminal)
            FilesScreen(connection: connection)
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(PhoneNavigation.Tab.files)
        }
        .sheet(item: $navigation.card) { ref in
            CardScreen(projectID: ref.projectID, cardID: ref.cardID, connection: connection)
        }
        .task(id: paired?.service) {
            connection.onServerName = { name in
                guard var updated = paired, updated.macName != name else { return }
                updated.macName = name
                PairedMacStore.save(updated)
                paired = updated
            }
            connection.onRelayAddress = { address in
                // A quick tunnel's address changes when the Mac restarts; the
                // Mac says the current one on every connect.
                guard var updated = paired, updated.relayURL != address else { return }
                updated.relayURL = address
                PairedMacStore.save(updated)
                paired = updated
            }
            connect()
        }
        .onChange(of: PushRegistration.shared.token) { _, _ in
            // Apple answers asynchronously, usually after the socket is already
            // up, so the token is sent when it arrives rather than at connect.
            connection.sendPushTokenIfAvailable()
        }
        .onChange(of: browser.found.map(\.name)) { _, _ in
            // The Mac appeared on the network — possibly for the first time,
            // possibly after waking. Either way it is now reachable.
            if !connection.state.isConnected { connect() }
        }
    }

    /// Bonjour first: on the same Wi-Fi it is the direct route, and a name
    /// rather than a remembered address — see `BoardBrowser`. Away from it the
    /// Mac is invisible to Bonjour, so dial its tailnet name instead, if the
    /// pairing code carried one. A tailnet connection that is up is kept even
    /// once Bonjour sees the Mac again — dropping a working socket to switch
    /// routes would cost more than the route saves; if the tailnet dial never
    /// connected, `onChange(of: browser.found)` retries through Bonjour.
    ///
    /// Last, the Mac's Cloudflare Tunnel, if it offered one: nothing to install
    /// on the phone, and sealed with the pairing key so Cloudflare only
    /// forwards it.
    private func connect() {
        guard let paired else { return }
        if let endpoint = browser.endpoint(named: paired.service) {
            connection.connect(to: endpoint, key: paired.key, route: .local)
        } else if let host = paired.remoteHost, let port = paired.remotePort,
                  let endpoint = BoardTransport.remoteEndpoint(host: host, port: port) {
            connection.connect(to: endpoint, key: paired.key, route: .tailnet)
        } else if let relay = paired.relayURL, let endpoint = BoardTransport.relayEndpoint(relay) {
            connection.connect(to: endpoint, key: paired.key, sealed: true)
        }
    }
}
