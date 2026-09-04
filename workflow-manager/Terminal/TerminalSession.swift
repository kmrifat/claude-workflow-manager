//
//  TerminalSession.swift
//  workflow-manager
//
//  One terminal: a persistent interactive shell, and the screen it draws on.
//
//  A saved command is not a special kind of process — the session starts a
//  shell and *types* the command into it. That is why the prompt, history,
//  Ctrl-C and `cd` all behave normally afterwards, and why there is only one
//  code path to get wrong.
//
//  The screen is SwiftTerm's `TerminalView`, which is the same split VS Code
//  makes: our own pty on one side (`InteractiveShell`, the `node-pty` half) and
//  a maintained xterm emulator on the other (the `xterm.js` half). It is owned
//  by the *session*, not by the pane that shows it, for the same reason the
//  shell is: switching tabs must not lose the screen.
//
//  Output arrives on a background queue in 8KB chunks and has to reach the
//  view. It is buffered under a lock and fed on a timer rather than per chunk: a
//  webpack rebuild emits hundreds of writes a second, and a redraw each spends
//  the whole frame budget in layout.
//

import AppKit
import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case idle
        case running
        case exited(code: Int32)
        case failed(String)
    }

    nonisolated let id: UUID
    /// `nil` for an ad-hoc terminal with no saved command behind it.
    nonisolated let commandUUID: UUID?

    private(set) var title: String
    private(set) var command: String
    private(set) var directory: URL
    private(set) var state: State = .idle
    private(set) var startedAt: Date?

    /// The screen: emulator, renderer, selection and keyboard in one view.
    ///
    /// Not observable — it is an `NSView` that mutates constantly and redraws
    /// itself, so putting it in the observation graph would invalidate SwiftUI
    /// on every byte for no gain.
    @ObservationIgnored let terminalView: SwiftTerm.TerminalView

    private var shell: InteractiveShell?
    /// Whether the last close was asked for.
    ///
    /// A shell told to go away exits non-zero — SIGHUP leaves 129, and `exit`
    /// from a job-control shell often leaves 1 — so reporting the raw code makes
    /// a perfectly normal close look like a crash.
    private var wasStoppedDeliberately = false
    @ObservationIgnored private let incoming = ByteBuffer()
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    /// 20fps: smooth to read, and cheap.
    private static let drainInterval: Duration = .milliseconds(50)

    /// Watches this session on behalf of connected phones. One slot rather than
    /// a list: the relay is a single object that mirrors every session, and the
    /// Mac's own UI needs none of this because it observes the session directly.
    @ObservationIgnored weak var mirror: (any TerminalSessionMirror)?

    /// Recent raw output, so a phone attaching to a session that has been
    /// running for an hour sees a screen rather than a blank one.
    @ObservationIgnored private var replay = ReplayBuffer()

    /// Raw pty bytes, not rendered text. Fed to the phone's own emulator, it
    /// reproduces the Mac's screen exactly — colours, cursor moves, the lot.
    /// Sending the rendered buffer instead was the obvious alternative and
    /// throws away everything that makes a terminal look like one.
    var replayData: Data { replay.contents }

    init(
        id: UUID = UUID(),
        commandUUID: UUID? = nil,
        title: String,
        command: String,
        directory: URL
    ) {
        self.id = id
        self.commandUUID = commandUUID
        self.title = title
        self.command = command
        self.directory = directory
        self.terminalView = SwiftTerm.TerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 400),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        configureTerminalView()
    }

    var isRunning: Bool { state == .running }

    var statusSummary: String {
        switch state {
        case .idle:                "Not started"
        case .running:             "Shell running"
        case .exited(let code):    code == 0 ? "Closed" : "Closed (\(code))"
        case .failed(let message): message
        }
    }

    /// The grid the shell believes it has, which is the size anything mirroring
    /// this session has to render at. Exposed here so callers do not have to
    /// reach through to the emulator — the screen being SwiftTerm is this file's
    /// business and nobody else's.
    var gridSize: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Everything on screen and in scrollback, for "Copy Output".
    var plainTextOutput: String {
        let data = terminalView.getTerminal().getBufferAsData()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Lifecycle

    /// Starts the shell if it is not already up.
    func startShell() {
        guard !isRunning else { return }

        let terminal = terminalView.getTerminal()
        terminal.resetToInitialState()
        state = .running
        startedAt = .now
        // Reset per run, or one deliberate close would mask every later crash.
        wasStoppedDeliberately = false
        // The screen was just cleared, so replaying the previous run to a phone
        // would show it output this session no longer has.
        replay.reset()
        mirror?.sessionDidChangeState(self)

        let shell = InteractiveShell()
        self.shell = shell
        let buffer = incoming

        do {
            try shell.start(
                directory: directory,
                columns: terminal.cols,
                rows: terminal.rows,
                onOutput: { data in buffer.append(data) },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in self?.finish(code: code) }
                }
            )
        } catch {
            state = .failed(error.localizedDescription)
            self.shell = nil
            mirror?.sessionDidChangeState(self)
            return
        }
        startDraining()
    }

    /// Starts the shell if needed, then types the saved command into it.
    ///
    /// The delay is for the shell's own startup: `.zshrc` and `oh-my-zsh` take
    /// a moment, and a command typed before `zle` is ready is swallowed.
    func runSavedCommand() {
        guard !command.isEmpty else { return }

        if !isRunning {
            startShell()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.isRunning else { return }
                self.send(self.command + TerminalKeys.enter)
            }
        } else {
            // Interrupt whatever is there so a restart does not type into a
            // running program.
            send(TerminalKeys.control("C") ?? "")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                self.send(self.command + TerminalKeys.enter)
            }
        }
    }

    /// Keystrokes, verbatim.
    func send(_ text: String) {
        shell?.send(text)
    }

    /// Keystrokes that are already bytes — what arrives from a phone, whose
    /// emulator has done the same encoding ours does. Not routed through the
    /// `String` version: a chunk can split a UTF-8 character or carry a lone
    /// `0x03`, and neither survives a round trip through `String`.
    func send(bytes: Data) {
        shell?.send(bytes)
    }

    func interrupt() {
        send(TerminalKeys.control("C") ?? "")
    }

    /// Ends the shell and everything it started.
    func stop() {
        wasStoppedDeliberately = true
        shell?.terminate()
    }

    /// Re-reads the saved command, so an edit takes effect next time.
    func update(title: String, command: String, directory: URL) {
        self.title = title
        self.command = command
        // Changing a running shell's directory would be a lie — it has its own
        // idea of where it is. Only an unstarted session picks up the new one.
        if !isRunning { self.directory = directory }
    }

    func clearScreen() {
        // What Ctrl-L does, and it keeps the shell's own state consistent.
        if isRunning {
            send(TerminalKeys.control("L") ?? "")
        } else {
            terminalView.getTerminal().resetToInitialState()
        }
    }

    // MARK: - Plumbing

    /// Colours and behaviour. The defaults are close, but three of them are
    /// wrong for this app: the light background, Option-as-Meta (which we want,
    /// so it stays) and mouse reporting (likewise).
    private func configureTerminalView() {
        terminalView.terminalDelegate = self
        // Option sends ESC, the way a terminal does; Command stays with the app
        // so ⌘C, ⌘V and the menu bar keep working.
        terminalView.optionAsMetaKey = true
        // So a click in `vim` or `htop` lands where it was aimed. Selection is
        // still reachable while a program grabs the mouse: hold Shift.
        terminalView.allowMouseReporting = true

        terminalView.nativeBackgroundColor = NSColor(
            srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1
        )
        terminalView.nativeForegroundColor = NSColor(
            srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1
        )
        terminalView.caretColor = NSColor(
            srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 0.85
        )
        terminalView.installColors(Self.palette)

        // SwiftTerm keeps 500 lines of history, which is a couple of seconds of
        // a chatty dev server. `changeHistorySize` also updates the options the
        // buffer is rebuilt from, so it survives the reset in `startShell`.
        terminalView.getTerminal().changeHistorySize(Self.scrollbackLines)
    }

    /// Matches what the app's own emulator kept before SwiftTerm replaced it.
    private static let scrollbackLines = 5_000

    /// The first sixteen ANSI colours, on a dark background. The other 240 are
    /// generated by the emulator from the standard cube.
    ///
    /// SwiftTerm's components are 16-bit, and only that initialiser is public —
    /// hence `× 257`, which maps 0…255 onto 0…65535 exactly (0xFF → 0xFFFF).
    private static let palette: [SwiftTerm.Color] = [
        rgb(0x42, 0x45, 0x4D),   // black
        rgb(0xEB, 0x66, 0x66),   // red
        rgb(0x78, 0xCC, 0x70),   // green
        rgb(0xE6, 0xBF, 0x61),   // yellow
        rgb(0x6B, 0xA3, 0xED),   // blue
        rgb(0xC7, 0x87, 0xE6),   // magenta
        rgb(0x5C, 0xC7, 0xD1),   // cyan
        rgb(0xC7, 0xC9, 0xD1),   // white
        rgb(0x73, 0x78, 0x82),   // bright black
        rgb(0xFF, 0x85, 0x85),   // bright red
        rgb(0x94, 0xE6, 0x8A),   // bright green
        rgb(0xFA, 0xDB, 0x7A),   // bright yellow
        rgb(0x8C, 0xBD, 0xFF),   // bright blue
        rgb(0xE0, 0xA6, 0xFF),   // bright magenta
        rgb(0x7A, 0xE6, 0xF0),   // bright cyan
        rgb(0xF5, 0xF5, 0xF7),   // bright white
    ]

    private static func rgb(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    private func startDraining() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                guard let self else { return }
                self.drain()
                if !self.isRunning, self.incoming.isEmpty { return }
            }
        }
    }

    private func drain() {
        let data = incoming.take()
        guard !data.isEmpty else { return }
        terminalView.feed(byteArray: [UInt8](data)[...])
        replay.append(data)
        mirror?.session(self, didProduce: data)
    }

    private func finish(code: Int32) {
        drain()
        // A shell we asked to close reports whatever signal killed it. That is
        // not information the user needs, and shown as an exit code it reads as
        // a failure.
        state = .exited(code: wasStoppedDeliberately ? 0 : code)
        shell = nil
        drainTask?.cancel()
        drainTask = nil
        mirror?.sessionDidChangeState(self)
        Task { @MainActor [weak self] in self?.drain() }
    }
}

// MARK: - Mirroring to a phone

/// How a session reports itself to whoever is relaying it elsewhere — today the
/// phone client, through `RepositoryService`.
///
/// A protocol rather than a closure so that the two events stay together: a
/// mirror that forwarded output but missed an exit would leave a phone watching
/// a dev server that died ten minutes ago.
@MainActor
protocol TerminalSessionMirror: AnyObject {
    func session(_ session: TerminalSession, didProduce data: Data)
    func sessionDidChangeState(_ session: TerminalSession)
}

/// The tail of a session's output, for a phone that attaches late.
///
/// Bytes, not lines: this is fed straight into another emulator, so it has to be
/// the same stream the Mac's emulator saw. The cap is generous enough to hold a
/// screenful of almost anything and small enough that a dozen idle sessions cost
/// nothing worth measuring.
private struct ReplayBuffer {
    private(set) var contents = Data()
    private let cap = 256 * 1024

    mutating func append(_ data: Data) {
        contents.append(data)
        guard contents.count > cap else { return }
        // Trim to a line boundary. Cutting mid-escape-sequence hands the phone's
        // emulator a fragment like `[31m`, which it prints as text — a screen
        // that opens with a line of garbage looks like a decoding bug.
        let excess = contents.count - cap
        let tail = contents.dropFirst(excess)
        if let newline = tail.firstIndex(of: 0x0A) {
            contents = Data(tail[tail.index(after: newline)...])
        } else {
            contents = Data(tail)
        }
    }

    mutating func reset() {
        contents = Data()
    }
}

// MARK: - The view's side of the wire

/// `@preconcurrency` because `TerminalViewDelegate` carries no isolation of its
/// own. Every call comes from an `NSView` on the main thread, which is what the
/// annotation asserts rather than assumes.
///
/// Every `TerminalView` below is written out in full: this app has its own
/// `TerminalView`, the SwiftUI pane in `Views/Terminal/`, and an unqualified
/// name resolves to *that* one — which fails as "does not conform to protocol"
/// with no mention of the two types it is actually comparing.
extension TerminalSession: @preconcurrency TerminalViewDelegate {
    /// Everything the user types, pastes, or clicks while a program is reading
    /// the mouse. The view does the encoding — bracketed paste included, which
    /// is what stops a multi-line paste from executing itself line by line.
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        shell?.send(Data(data))
    }

    /// The view sizes itself from the font and its frame, then reports the grid
    /// it settled on. Pushing that to the pty is what raises `SIGWINCH` and
    /// makes `$COLUMNS` agree with what is on screen.
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        shell?.resize(columns: newCols, rows: newRows)
    }

    /// OSC 52, which lets a program running in the terminal write the system
    /// clipboard. Deliberately ignored — silently replacing what someone copied
    /// is not a thing a shell should be able to do behind their back, and it is
    /// what SwiftTerm's own default does.
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// A lock-guarded byte queue. The pty reader fills it from a background queue;
/// the session empties it on the main actor.
/// `nonisolated` deliberately. The target defaults types to `@MainActor`, which
/// this must not inherit: the pty's read handler calls `append` from a
/// background thread, which is the whole reason the class carries its own lock
/// and is `@unchecked Sendable`. Inheriting main-actor isolation made that call
/// a warning today and an error under the Swift 6 language mode.
private nonisolated final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    /// A runaway process must not exhaust memory before the drain catches up.
    private let cap = 1 << 20

    var isEmpty: Bool { lock.withLock { storage.isEmpty } }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
            if storage.count > cap {
                storage.removeFirst(storage.count - cap)
            }
        }
    }

    func take() -> Data {
        lock.withLock {
            defer { storage = Data() }
            return storage
        }
    }
}
