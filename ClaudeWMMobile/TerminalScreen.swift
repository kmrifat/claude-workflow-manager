//
//  TerminalScreen.swift
//  ClaudeWMMobile
//
//  The Mac's terminals, on the phone.
//
//  ## The phone renders; it does not receive a picture
//
//  What arrives over the wire is raw pty output, and this feeds it to a
//  SwiftTerm emulator of its own — the same library the Mac uses. So colour,
//  cursor addressing, the alternate screen and `htop` all work, and the two
//  screens agree because they are running the same code over the same bytes.
//
//  ## It is the same session, not a copy
//
//  Attaching does not start anything. The dev server the Mac is running is the
//  one shown here, output goes to both, and typing here types there. That is the
//  point: the alternative — a second shell — is a second dev server fighting for
//  port 3000.
//
//  ## Why the grid is the Mac's, and not the phone's
//
//  A pty has one size. Resizing it to fit a handset would reflow the window
//  someone may be watching on the desktop, mid-build. So the phone renders at
//  whatever grid the Mac has and scales it down to fit the width — a 120-column
//  build log is small on a phone, and legible, which is better than the same log
//  hard-wrapped at 40 columns.
//

import SwiftUI
import SwiftTerm
import ClaudeWMWire

struct TerminalScreen: View {
    let connection: BoardConnection

    @State private var attached: WireTerminalRef?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if attached == nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                connection.listTerminals()
                            }
                        }
                    }
                }
        }
        // Asked for on appearing and on every reconnect: sessions come and go on
        // the Mac while the phone is in a pocket.
        .task(id: connection.state) { connection.listTerminals() }
        .task(id: connection.selectedProjectID) { connection.listTerminals() }
    }

    @ViewBuilder
    private var content: some View {
        if let refusal = connection.repositoryAccessRefused {
            ContentUnavailableView {
                Label("Terminal is off", systemImage: "lock")
            } description: {
                Text(refusal)
            }
        } else if !connection.state.isConnected {
            ContentUnavailableView(
                "Not connected",
                systemImage: "wifi.exclamationmark",
                description: Text("Your Mac isn’t reachable right now.")
            )
        } else if let attached {
            AttachedTerminalView(terminal: attached, connection: connection) {
                connection.detachTerminal(attached.id)
                self.attached = nil
                connection.listTerminals()
            }
        } else if connection.terminals.isEmpty {
            ContentUnavailableView(
                "No terminals",
                systemImage: "apple.terminal",
                description: Text("This board has no saved commands, and no terminal is open on the Mac.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(connection.terminals) { terminal in
            Button {
                attached = terminal
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: terminal.isSavedCommand ? "play.rectangle" : "apple.terminal")
                        .foregroundStyle(terminal.isRunning ? .green : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(terminal.title)
                            .font(.body)
                        Text(terminal.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .refreshable { connection.listTerminals() }
    }
}

// MARK: - One attached session

private struct AttachedTerminalView: View {
    let terminal: WireTerminalRef
    let connection: BoardConnection
    let onBack: () -> Void

    /// The live state of this session, replaced as `terminalState` arrives, so
    /// the Start/Stop button and the status line follow the Mac.
    @State private var current: WireTerminalRef

    init(terminal: WireTerminalRef, connection: BoardConnection, onBack: @escaping () -> Void) {
        self.terminal = terminal
        self.connection = connection
        self.onBack = onBack
        _current = State(initialValue: terminal)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalSurface(
                sessionID: terminal.id,
                grid: (current.cols, current.rows),
                connection: connection
            )
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Terminals", systemImage: "chevron.left", action: onBack)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if current.isRunning {
                        Button("Restart", systemImage: "arrow.clockwise") {
                            connection.act(.restart, on: terminal.id)
                        }
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            connection.act(.stop, on: terminal.id)
                        }
                    } else {
                        Button("Start", systemImage: "play.fill") {
                            connection.act(.start, on: terminal.id)
                        }
                    }
                } label: {
                    Label("Session", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            connection.onTerminalState = { sessionID, ref in
                guard sessionID == terminal.id else { return }
                current = ref
            }
        }
        .onDisappear { connection.onTerminalState = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(current.isRunning ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(current.title).font(.subheadline.weight(.medium))
            Text(current.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(current.cols)×\(current.rows)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - The emulator

/// SwiftTerm's iOS view, wired to the socket instead of to a local process.
///
/// `TerminalView` here is SwiftTerm's `UIView`. This client has no type of that
/// name, unlike the Mac app — but it is written out in full anyway, because the
/// mistake it prevents there costs an afternoon.
private struct TerminalSurface: UIViewRepresentable {
    let sessionID: String
    let grid: (cols: Int, rows: Int)
    let connection: BoardConnection

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID, connection: connection)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1)
        view.installColors(TerminalPalette.dark)
        view.getTerminal().changeHistorySize(5_000)
        context.coordinator.view = view

        connection.onTerminalAttached = { [weak coordinator = context.coordinator] id, ref, replay in
            guard id == sessionID, let coordinator else { return }
            coordinator.paint(replay, resizingTo: (ref.cols, ref.rows))
        }
        connection.onTerminalOutput = { [weak coordinator = context.coordinator] id, data in
            guard id == sessionID, let coordinator else { return }
            coordinator.feed(data)
        }
        connection.attachTerminal(sessionID)
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.resize(to: grid)
    }

    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.connection.onTerminalAttached = nil
        coordinator.connection.onTerminalOutput = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let sessionID: String
        let connection: BoardConnection
        weak var view: SwiftTerm.TerminalView?

        init(sessionID: String, connection: BoardConnection) {
            self.sessionID = sessionID
            self.connection = connection
        }

        /// The replay: reset first, because these bytes are a *whole* screen
        /// from the beginning. Fed onto a view that already has content, a
        /// reattach would paint the new output over the old.
        func paint(_ replay: Data, resizingTo grid: (cols: Int, rows: Int)) {
            view?.getTerminal().resetToInitialState()
            resize(to: grid)
            feed(replay)
        }

        func feed(_ data: Data) {
            guard !data.isEmpty else { return }
            view?.feed(byteArray: [UInt8](data)[...])
        }

        /// Match the Mac's grid rather than the phone's width. `resize` here
        /// only tells the emulator how wide the incoming stream believes it is;
        /// nothing is sent back to the pty, so the desktop window is untouched.
        func resize(to grid: (cols: Int, rows: Int)) {
            guard let view, grid.cols > 0, grid.rows > 0 else { return }
            let terminal = view.getTerminal()
            guard terminal.cols != grid.cols || terminal.rows != grid.rows else { return }
            terminal.resize(cols: grid.cols, rows: grid.rows)
        }

        // MARK: TerminalViewDelegate

        /// Everything typed, including what the accessory row above the keyboard
        /// sends — Esc, Tab, Ctrl-C, the arrows. SwiftTerm encodes them exactly
        /// as the Mac's copy does, so these bytes go to the pty unaltered.
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            connection.sendTerminalInput(Data(data), to: sessionID)
        }

        /// Deliberately empty. The size of this screen is not the pty's business
        /// — see the note at the top of this file.
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}

        /// An OSC 8 hyperlink, tapped.
        ///
        /// Implemented rather than inherited: SwiftTerm defaults this only on
        /// macOS, where it hands *any* scheme to `NSWorkspace`. Terminal output
        /// is whatever a program printed, and OSC 8 lets it label a link one
        /// thing and point it somewhere else — so this opens `http` and `https`
        /// and nothing else. A `file://` or custom-scheme link from a build log
        /// is not something a tap should act on.
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let encoded = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: encoded),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            UIApplication.shared.open(url)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    }
}

/// The Mac's palette, so the same build log is the same colours on both screens.
enum TerminalPalette {
    static let dark: [SwiftTerm.Color] = [
        rgb(0x42, 0x45, 0x4D), rgb(0xEB, 0x66, 0x66), rgb(0x78, 0xCC, 0x70), rgb(0xE6, 0xBF, 0x61),
        rgb(0x6B, 0xA3, 0xED), rgb(0xC7, 0x87, 0xE6), rgb(0x5C, 0xC7, 0xD1), rgb(0xC7, 0xC9, 0xD1),
        rgb(0x73, 0x78, 0x82), rgb(0xFF, 0x85, 0x85), rgb(0x94, 0xE6, 0x8A), rgb(0xFA, 0xDB, 0x7A),
        rgb(0x8C, 0xBD, 0xFF), rgb(0xE0, 0xA6, 0xFF), rgb(0x7A, 0xE6, 0xF0), rgb(0xF5, 0xF5, 0xF7),
    ]

    /// SwiftTerm's components are 16-bit and only that initialiser is public;
    /// × 257 maps 0…255 onto 0…65535 exactly.
    private static func rgb(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }
}
