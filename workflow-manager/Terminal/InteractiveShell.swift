//
//  InteractiveShell.swift
//  workflow-manager
//
//  A persistent interactive login shell on a pty.
//
//  `PTYProcess` runs one command and exits. This starts `zsh -il` and leaves it
//  running, which is what makes the terminal a terminal: `oh-my-zsh` loads and
//  draws its prompt, history and arrow keys work because `zle` is there, Ctrl-C
//  reaches the foreground job through the tty, and `cd` persists because it is
//  the same shell throughout.
//
//  Running a saved command is then just typing it: write `npm run dev\n` to the
//  master. There is no separate code path for it, and the result is a session
//  you can interrupt and reuse.
//

import Foundation
import Darwin

nonisolated final class InteractiveShell: @unchecked Sendable {

    enum Failure: Error, LocalizedError {
        case ptyUnavailable
        case spawnFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .ptyUnavailable:
                return "Could not allocate a pseudo-terminal."
            case .spawnFailed(let code):
                return "Could not start the shell (\(String(cString: strerror(code))))."
            }
        }
    }

    private let lock = NSLock()
    private var pid: pid_t = -1
    private var master: Int32 = -1
    private var exited = false

    var isRunning: Bool { lock.withLock { pid > 0 && !exited } }

    /// Starts the shell in `directory`.
    func start(
        directory: URL,
        columns: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&masterFD, &slaveFD, nil, nil, &window) == 0 else {
            throw Failure.ptyUnavailable
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Deliberately no `COLUMNS`/`LINES`: the pty's own window size is the
        // truth, the shell reads it from there and keeps it current on
        // SIGWINCH. Exporting them just creates a second copy that goes stale
        // the first time the pane is resized.
        environment["COLUMNS"] = nil
        environment["LINES"] = nil
        // A GUI app is launched with a minimal PATH; the login shell's own
        // profile rebuilds it, but seed something sane for anything that reads
        // PATH before that happens.
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }

        // `-i -l`: interactive so `.zshrc` (and therefore oh-my-zsh, aliases,
        // nvm and `zle`) loads, login so `.zprofile` does too. No `-c`, so the
        // shell stays alive and owns the session.
        // Everything the child needs is built as raw C memory *before* the
        // fork. After it, only async-signal-safe C calls are allowed — no Swift
        // allocation, no ARC, no bridging.
        let argvStrings = [shell, "-i", "-l"]
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: argvStrings.count + 1)
        for (index, value) in argvStrings.enumerated() { argv[index] = strdup(value) }
        argv[argvStrings.count] = nil

        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: envStrings.count + 1)
        for (index, value) in envStrings.enumerated() { envp[index] = strdup(value) }
        envp[envStrings.count] = nil

        let shellPath = strdup(shell)
        let workingDirectory = strdup(directory.path(percentEncoded: false))

        defer {
            for index in 0..<argvStrings.count { free(argv[index]) }
            for index in 0..<envStrings.count { free(envp[index]) }
            argv.deallocate()
            envp.deallocate()
            free(shellPath)
            free(workingDirectory)
        }

        // The shell needs a *controlling terminal*, not merely a pty on its
        // standard descriptors. Without one there is no job control: the tty's
        // foreground process group stays 0, so SIGINT is delivered to nothing.
        // `^C` still echoes — the line discipline draws it — which makes it
        // look like Ctrl-C worked right up until you notice the job never died.
        //
        // Granting one requires `ioctl(TIOCSCTTY)` in the child, between
        // `setsid` and `exec`. `posix_spawn` has no hook for that, and neither
        // of the alternatives works: opening the slave by path via a spawn file
        // action does not confer a controlling terminal here, and setting
        // `TIOCSPGRP` from the parent fails because a process group cannot be
        // foreground for a terminal that belongs to no session. Both were tried;
        // `ps -o tpgid=` reported 0 either way.
        //
        // So: `fork`. Swift marks it unavailable, so it is resolved through
        // `dlsym`. Everything between the fork and the exec is async-signal-safe
        // C — the allocations all happened above.
        guard let forkSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            close(masterFD)
            close(slaveFD)
            throw Failure.spawnFailed(code: ENOSYS)
        }
        let forkFunction = unsafeBitCast(
            forkSymbol,
            to: (@convention(c) () -> pid_t).self
        )

        let spawnedPID = forkFunction()
        if spawnedPID == 0 {
            // --- child ---
            setsid()
            _ = ioctl(slaveFD, TIOCSCTTY, 0)

            dup2(slaveFD, 0)
            dup2(slaveFD, 1)
            dup2(slaveFD, 2)
            if slaveFD > 2 { close(slaveFD) }
            close(masterFD)

            _ = chdir(workingDirectory)

            // A shell that inherited an ignored SIGINT is the bug this is all
            // about, so the job-control signals are reset to their defaults.
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            signal(SIGTSTP, SIG_DFL)
            signal(SIGTTIN, SIG_DFL)
            signal(SIGTTOU, SIG_DFL)
            signal(SIGPIPE, SIG_DFL)

            execve(shellPath, argv, envp)
            _exit(127)      // reached only if exec failed
        }

        close(slaveFD)
        guard spawnedPID > 0 else {
            close(masterFD)
            throw Failure.spawnFailed(code: errno)
        }

        lock.withLock {
            pid = spawnedPID
            master = masterFD
            exited = false
        }

        readLoop(masterFD, onOutput: onOutput)
        waitLoop(spawnedPID, onExit: onExit)
    }

    // MARK: - Input

    /// Sends bytes to the shell exactly as a keyboard would.
    func send(_ data: Data) {
        let descriptor = lock.withLock { master }
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    func send(_ text: String) {
        send(Data(text.utf8))
    }

    /// Tells the shell the window changed, so it redraws its prompt and
    /// full-screen programs re-lay out. This is what `SIGWINCH` is for, and the
    /// kernel raises it when the size is set on the pty.
    func resize(columns: Int, rows: Int) {
        let descriptor = lock.withLock { master }
        guard descriptor >= 0 else { return }
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(descriptor, TIOCSWINSZ, &window)
    }

    /// Ends the shell and everything it started.
    func terminate() {
        let target = lock.withLock { pid }
        guard target > 0 else { return }
        kill(-target, SIGHUP)
        kill(-target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-target, SIGKILL)
        }
    }

    // MARK: - Plumbing

    private func readLoop(_ descriptor: Int32, onOutput: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    onOutput(Data(buffer[0..<count]))
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break   // EIO: the far end closed, which is how a pty ends
                }
            }
            close(descriptor)
        }
    }

    private func waitLoop(_ target: pid_t, onExit: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(target, &status, 0) < 0 && errno == EINTR { continue }
            let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            self?.lock.withLock {
                self?.exited = true
                self?.pid = -1
            }
            onExit(code)
        }
    }
}

// MARK: - Key encoding

/// Turns key presses into the bytes a terminal sends.
///
/// This is the other half of being a real terminal: arrows have to arrive as
/// `ESC[A`, Ctrl-C as a single `0x03` so the tty raises SIGINT, and Tab as a
/// literal tab so completion runs in the shell rather than moving focus.
nonisolated enum TerminalKeys {
    static let up = "\u{1B}[A"
    static let down = "\u{1B}[B"
    static let right = "\u{1B}[C"
    static let left = "\u{1B}[D"
    static let home = "\u{1B}[H"
    static let end = "\u{1B}[F"
    static let pageUp = "\u{1B}[5~"
    static let pageDown = "\u{1B}[6~"
    static let delete = "\u{1B}[3~"
    static let backspace = "\u{7F}"
    static let tab = "\t"
    static let enter = "\r"
    static let escape = "\u{1B}"

    /// Ctrl-<letter> is the letter with the top three bits cleared: Ctrl-C is
    /// 0x03, Ctrl-D 0x04, Ctrl-Z 0x1A.
    static func control(_ character: Character) -> String? {
        guard let ascii = character.uppercased().first?.asciiValue,
              ascii >= 64, ascii <= 95 || character == "?"
        else { return nil }
        return String(UnicodeScalar(ascii & 0x1F))
    }

    /// Option-<key> is sent as ESC then the key.
    static func meta(_ text: String) -> String {
        "\u{1B}" + text
    }
}
