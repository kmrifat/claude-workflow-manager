//
//  BoardSharingView.swift
//  workflow-manager
//
//  Where the user turns the phone connection on, and sees the QR code that
//  pairs one.
//
//  Deliberately blunt about what is happening. Opening a listening socket on
//  someone's network is not a thing to phrase softly, and the copy here says
//  what is exposed, to whom, and how to take it back.
//

import SwiftUI
import ClaudeWMWire

struct BoardSharingView: View {
    @Environment(\.dismiss) private var dismiss
    let server: BoardServer

    @State private var pairingURL: URL?
    @State private var showKeyRotationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusRow
                    if server.state.isRunning {
                        qrSection
                        clientsSection
                    } else {
                        explanation
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 620)
        .onExitCommand { dismiss() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .foregroundStyle(.tint)
            Text("Phone Access")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch server.state {
        case .stopped:
            Label("Off", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running(let port):
            Label("Visible on this Wi-Fi network · port \(port)", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            // Named, not swallowed. The usual cause is the macOS
            // incoming-connections prompt being denied, and that is worth
            // saying rather than showing a generic failure.
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Control this board from your phone")
                .font(.headline)
            Text("""
                Claude WM can serve your boards to the Claude WM app on your \
                phone, over your local Wi-Fi only. Nothing is published to the \
                internet and nothing is sent to a server.

                A phone can only connect if you have paired it by scanning the \
                code shown here. Your Mac has to be awake.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan with your phone")
                .font(.headline)

            if let pairingURL, let image = BoardPairing.qrCode(for: pairingURL) {
                HStack {
                    Spacer()
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)      // a blurred QR is an unreadable QR
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(.white)        // scanners want dark-on-light
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }

            Text("This code contains the key your phone needs. Treat it like a password — anyone who photographs it can reach your boards from this network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected")
                .font(.headline)
            if server.clients.isEmpty {
                Text("No phones connected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.clients) { client in
                    HStack {
                        Image(systemName: client.isReady ? "iphone" : "iphone.slash")
                            .foregroundStyle(client.isReady ? .primary : .secondary)
                        Text(client.name)
                        Spacer()
                        Button("Disconnect") { server.disconnect(client.id) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if server.state.isRunning {
                Button("Turn Off") { server.stop() }
            } else {
                Button("Turn On") { start() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            Button("Forget All Phones…") { showKeyRotationConfirmation = true }
                .disabled(BoardPairing.loadKey() == nil)
        }
        .padding(16)
        .confirmationDialog(
            "Forget all paired phones?",
            isPresented: $showKeyRotationConfirmation
        ) {
            Button("Forget All", role: .destructive) { rotate() }
        } message: {
            // One key, so revocation is all-or-nothing. Said plainly rather
            // than implying a device list that does not exist.
            Text("Every phone you have paired will stop working and will need to scan a new code.")
        }
    }

    // MARK: - Actions

    private func start() {
        let key = BoardPairing.currentKey()
        let name = BoardServer.defaultServiceName
        server.start(key: key, serviceName: name)
        pairingURL = try? BoardPairing.url(
            for: BoardPairing.Payload(key: key, service: name, mac: name)
        )
    }

    private func rotate() {
        let wasRunning = server.state.isRunning
        BoardPairing.rotateKey()
        // The listener holds the old key inside its TLS parameters, so it has
        // to be rebuilt for a rotation to mean anything.
        server.stop()
        if wasRunning { start() }
    }
}

#if DEBUG
#Preview {
    BoardSharingView(server: BoardServer())
}
#endif
