//
//  PairingView.swift
//  ClaudeWMMobile
//
//  Getting the key onto the phone.
//
//  Two routes, and the second is not a debug affordance: the camera route
//  requires the Mac and the phone to be in the same room, and pasting the URL
//  works in the Simulator, over Messages to yourself, and when the camera
//  permission has been denied.
//

import SwiftUI

struct PairingView: View {
    let browser: BoardBrowser
    let onPaired: (PairedMac) -> Void

    @State private var pastedCode = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("""
                        On your Mac, open Claude WM and choose **Phone Access…**, \
                        turn it on, and point your camera at the code it shows.
                        """)
                    .font(.callout)
                } header: {
                    Text("Pair with your Mac")
                }

                Section {
                    TextField("claudewm://pair?d=…", text: $pastedCode, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    Button("Pair") { pair() }
                        .disabled(pastedCode.isEmpty)
                } header: {
                    Text("Or paste the code")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if !browser.found.isEmpty {
                    Section {
                        ForEach(browser.found, id: \.name) { entry in
                            Label(entry.name, systemImage: "desktopcomputer")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Macs on this network")
                    } footer: {
                        // Seeing the Mac but not being paired is a confusing
                        // state unless it is named plainly.
                        Text("Visible, but not yet paired. Scan or paste its code to connect.")
                    }
                }
            }
            .navigationTitle("Claude WM")
        }
    }

    private func pair() {
        error = nil
        guard let url = URL(string: pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "That doesn’t look like a pairing code."
            return
        }
        do {
            let payload = try BoardPairingCode.payload(from: url)
            onPaired(PairedMac(key: payload.key, service: payload.service, macName: payload.mac))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
