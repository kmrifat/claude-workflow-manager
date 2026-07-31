//
//  ClaudeWMMobileApp.swift
//  ClaudeWMMobile
//
//  Claude WM's phone client. Reaches the Mac over the local network only —
//  there is no account, no server, and nothing leaves the Wi-Fi.
//

import SwiftUI

@main
struct ClaudeWMMobileApp: App {
    @State private var connection = BoardConnection()
    @State private var browser = BoardBrowser()
    @State private var paired = PairedMacStore.load()

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
                        let mac = PairedMac(key: pairing.key, service: pairing.service, macName: pairing.mac)
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
                BoardScreen(connection: connection, browser: browser, paired: $paired)
            }
        }
        .task { browser.start() }
    }
}
