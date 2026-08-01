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

    /// Same key `BoardNotifier` reads, so the two cannot drift.
    @AppStorage("boardNotificationsEnabled") private var notifyOnMoves = true

    @State private var pairingURL: URL?
    @State private var push = PushRegistry.shared
    @State private var pastedKey = ""
    @State private var showsKeyField = false
    /// Collapsed unless a key is already set up — see `pushSection`.
    @State private var showsPushSetup = PushRegistry.shared.isConfigured
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
                    Divider()
                    notificationsSection
                    Divider()
                    pushSection
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

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.headline)
            Toggle("Tell me when a card moves", isOn: $notifyOnMoves)
            // Says what it will *not* do, because that is the part people
            // otherwise discover by being annoyed.
            Text("Only for moves you didn’t make — Claude picking work up, or your phone. Your own drags stay quiet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Folded away, because it asks for something almost nobody has.
    ///
    /// Supplying an APNs auth key is developer plumbing, not a product setting:
    /// a person who buys this app has no key and never will. It is in the UI at
    /// all because the Mac is its own push provider, and a provider needs a
    /// credential from somewhere. The alternatives are worse — bundling a key
    /// hands it to every buyer (and this one is team-scoped, so a leak reaches
    /// every app on the account), and a relay that would hide it is the backend
    /// this product does not have.
    ///
    /// So: collapsed, honest about who it is for, and out of the way of someone
    /// who only wants their board on their phone.
    @ViewBuilder
    private var pushSection: some View {
        DisclosureGroup(isExpanded: $showsPushSetup) {
            pushSetup.padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push to a sleeping phone")
                        .font(.headline)
                    Text("Advanced — needs an Apple developer push key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if push.isConfigured {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var pushSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications reach your phone only while Claude WM is open on it — iOS suspends the app seconds after the screen goes off. An Apple push key lets this Mac notify it while it sleeps. Only phones that aren’t currently connected get a push, so you never see the same move twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Key ID", text: Binding(
                    get: { push.keyID }, set: { push.keyID = $0 }
                ))
                TextField("Team ID", text: Binding(
                    get: { push.teamID }, set: { push.teamID = $0 }
                ))
            }
            .textFieldStyle(.roundedBorder)

            if push.hasKey {
                HStack {
                    Text("Auth key stored in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { push.forgetKey() }
                        .buttonStyle(.link)
                }
            } else if showsKeyField {
                TextEditor(text: $pastedKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                HStack {
                    Spacer()
                    Button("Save Key") {
                        push.storeKey(pastedKey)
                        pastedKey = ""
                        showsKeyField = false
                    }
                    .disabled(!pastedKey.contains("PRIVATE KEY"))
                }
            } else {
                Button("Paste Auth Key (.p8)…") { showsKeyField = true }
            }

            if push.registeredDeviceCount > 0 {
                Text("^[\(push.registeredDeviceCount) phone](inflect: true) registered for push.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = push.lastError {
                // Apple's rejection reason verbatim: "InvalidProviderToken" or
                // "BadDeviceToken" is the only actionable part, and paraphrasing
                // it just makes it un-searchable.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
