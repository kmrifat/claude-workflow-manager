//
//  RepositoryService.swift
//  workflow-manager
//
//  Terminal and Files, for the phone. `BoardService` owns what a board message
//  means; this owns what a *repository* message means, and the two are kept
//  apart because they are answerable in different ways: a board mutation is one
//  of a fixed list of verbs, and a terminal is a byte pipe to a shell.
//
//  ## Off by default, and separately from the board
//
//  Sharing a board and handing out a shell are not the same decision, so they
//  are not the same switch. `RemoteAccess.isEnabled` gates every message here,
//  is checked on each one rather than once at connect time — so revoking it
//  takes effect on a phone that is already connected — and every refusal is
//  `.forbidden` rather than `.unauthorized`, because "turn the setting on" and
//  "pair this device again" send someone to different screens.
//
//  ## Why the phone renders, and the Mac only relays
//
//  What crosses the wire is raw pty output, which the phone feeds to an emulator
//  of its own. Both ends run the same SwiftTerm, so the phone's screen is the
//  Mac's screen, including colour, cursor addressing and the alternate screen.
//  Sending rendered text was the alternative and loses all three — `htop` over
//  that link is a wall of nonsense.
//
//  The pty is *not* resized to the phone's grid. The session is shared, and a
//  phone attaching to a terminal someone is watching on the desktop must not
//  reflow it to 40 columns. The phone renders at the Mac's size and scrolls.
//

import Foundation
import ClaudeWMWire

@MainActor
final class RepositoryService {

    private let terminals: TerminalStateStore
    /// Resolving a project id stays in `BoardService`, which is the only place
    /// that talks to SwiftData.
    private let project: (String) -> Project?

    /// Which clients are watching which session. A session with no watchers is
    /// not mirrored at all, so an idle phone costs a disconnected socket and
    /// nothing else.
    private var watchers: [UUID: Set<UUID>] = [:]

    private weak var server: BoardServer?

    init(terminals: TerminalStateStore, project: @escaping (String) -> Project?) {
        self.terminals = terminals
        self.project = project
    }

    // MARK: - Dispatch

    /// Returns false for anything this service has no business answering, so
    /// `BoardService` can fall through to its own handling.
    func handle(_ message: ClientMessage, from client: UUID, on server: BoardServer) -> Bool {
        switch message {
        case .listTerminals, .attachTerminal, .detachTerminal, .terminalInput,
             .terminalAction, .listDirectory, .readFile:
            break
        default:
            return false
        }

        self.server = server

        guard RemoteAccess.isEnabled else {
            server.send(.failure(WireFailure(
                code: .forbidden,
                message: "Terminal and file access is switched off on this Mac. Turn it on in Phone Access…"
            )), to: client)
            return true
        }

        switch message {
        case .listTerminals(let projectID):
            guard let project = project(projectID) else { return refuseProject(client, server) }
            let model = sessions(for: project)
            server.send(.terminals(projectID: projectID, model.sessions.map(reference(to:))), to: client)

        case .attachTerminal(let projectID, let sessionID):
            guard let project = project(projectID) else { return refuseProject(client, server) }
            guard let session = session(sessionID, in: project) else {
                return refuseSession(client, server)
            }
            // The relay is the session's mirror for as long as anyone is
            // watching. Set here rather than when the session is created: the
            // store makes sessions for its own reasons and should not know this
            // exists.
            session.mirror = self
            watchers[session.id, default: []].insert(client)
            server.send(.terminalAttached(
                sessionID: sessionID,
                terminal: reference(to: session),
                replay: session.replayData
            ), to: client)

        case .detachTerminal(let sessionID):
            guard let id = UUID(uuidString: sessionID) else { break }
            detach(client, from: id)

        case .terminalInput(let sessionID, let data):
            guard let session = anySession(sessionID) else {
                return refuseSession(client, server)
            }
            // Only a client that attached may type. Not a security boundary —
            // it already holds the pairing key — but it keeps "I am watching
            // this" and "I am driving this" the same statement, so a phone that
            // has been told the session ended cannot still be feeding it.
            guard watchers[session.id]?.contains(client) == true else {
                server.send(.failure(WireFailure(
                    code: .unknownSession,
                    message: "Attach to that terminal before typing into it."
                )), to: client)
                break
            }
            session.send(bytes: data)

        case .terminalAction(let sessionID, let action):
            guard let session = anySession(sessionID) else {
                return refuseSession(client, server)
            }
            switch action {
            case .start:   start(session)
            case .stop:    session.stop()
            case .restart: start(session)
            }

        case .listDirectory(let projectID, let path):
            guard let project = project(projectID) else { return refuseProject(client, server) }
            guard let root = repositoryRoot(of: project) else {
                return refuseNoRepository(client, server)
            }
            guard let directory = resolve(path, in: root) else {
                return refusePath(path, client, server)
            }
            let entries = FileTree.children(of: directory).compactMap { node -> WireFileNode? in
                guard let relative = RepositoryPath.relative(
                    node.url.standardizedFileURL.path,
                    to: root.standardizedFileURL.path
                ) else { return nil }
                return WireFileNode(
                    name: node.name,
                    path: relative,
                    isDirectory: node.isDirectory,
                    size: node.size
                )
            }
            server.send(.directory(
                projectID: projectID,
                path: RepositoryPath.sanitize(path) ?? "",
                entries: entries
            ), to: client)

        case .readFile(let projectID, let path):
            guard let project = project(projectID) else { return refuseProject(client, server) }
            guard let root = repositoryRoot(of: project) else {
                return refuseNoRepository(client, server)
            }
            guard let file = resolve(path, in: root) else {
                return refusePath(path, client, server)
            }
            server.send(.fileContent(
                projectID: projectID,
                path: RepositoryPath.sanitize(path) ?? "",
                content: wireContent(FileTree.read(file))
            ), to: client)

        default:
            // Unreachable: the guard above already returned for everything else.
            break
        }
        return true
    }

    /// A connection went away: stop mirroring to it. Without this a session
    /// keeps encoding output for a phone that is in someone's pocket.
    func clientDisconnected(_ client: UUID) {
        for (sessionID, clients) in watchers where clients.contains(client) {
            detach(client, from: sessionID)
        }
    }

    private func detach(_ client: UUID, from sessionID: UUID) {
        guard var clients = watchers[sessionID] else { return }
        clients.remove(client)
        if clients.isEmpty {
            watchers.removeValue(forKey: sessionID)
            // Leave `session.mirror` set: it is a weak slot, costs nothing, and
            // clearing it here would race a second phone attaching.
        } else {
            watchers[sessionID] = clients
        }
    }

    // MARK: - Sessions

    private func sessions(for project: Project) -> TerminalSessionsModel {
        let model = terminals.model(for: project.uuid)
        // The saved commands become sessions here, not only when someone opens
        // the Terminal tab on the Mac. A phone must be able to start a dev
        // server on a project the Mac has never displayed.
        model.sync(with: project)
        return model
    }

    private func session(_ id: String, in project: Project) -> TerminalSession? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return sessions(for: project).sessions.first { $0.id == uuid }
    }

    /// For messages that carry a session but no project — input and lifecycle,
    /// which arrive after an attach has already established both.
    private func anySession(_ id: String) -> TerminalSession? {
        guard let uuid = UUID(uuidString: id), watchers[uuid] != nil else { return nil }
        return terminals.session(uuid)
    }

    private func start(_ session: TerminalSession) {
        // An ad-hoc terminal has no saved command to type; a saved one does, and
        // `runSavedCommand` is also the restart path — it interrupts whatever is
        // running before retyping.
        if session.command.isEmpty {
            session.startShell()
        } else {
            session.runSavedCommand()
        }
    }

    private func reference(to session: TerminalSession) -> WireTerminalRef {
        let grid = session.gridSize
        return WireTerminalRef(
            id: session.id.uuidString,
            title: session.title,
            isRunning: session.isRunning,
            isSavedCommand: session.commandUUID != nil,
            status: session.statusSummary,
            cols: grid.cols,
            rows: grid.rows
        )
    }

    // MARK: - Files

    private func repositoryRoot(of project: Project) -> URL? {
        project.repoDirectory
    }

    /// Turns a path from the wire into a URL inside the repository, or nil.
    ///
    /// Two checks, and both are needed. `RepositoryPath.sanitize` rejects the
    /// obvious escapes as strings; resolving symlinks and re-testing containment
    /// catches the one strings cannot — a symlink committed *inside* the
    /// repository that points at `~/.ssh`. Neither check subsumes the other.
    private func resolve(_ path: String, in root: URL) -> URL? {
        guard let relative = RepositoryPath.sanitize(path) else { return nil }
        let candidate = relative.isEmpty ? root : root.appending(path: relative)

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard RepositoryPath.relative(resolved, to: resolvedRoot) != nil else { return nil }
        return candidate
    }

    private func wireContent(_ content: FileTree.Content) -> WireFileContent {
        switch content {
        case .text(let text):         .text(text)
        case .image(let data):        .image(data)
        case .binary(let size):       .binary(size: size)
        case .tooLarge(let size):     .tooLarge(size: size)
        case .unreadable(let reason): .unreadable(reason)
        }
    }

    // MARK: - Refusals

    private func refuseProject(_ client: UUID, _ server: BoardServer) -> Bool {
        server.send(.failure(WireFailure(
            code: .unknownProject,
            message: "That board is no longer on this Mac."
        )), to: client)
        return true
    }

    private func refuseSession(_ client: UUID, _ server: BoardServer) -> Bool {
        server.send(.failure(WireFailure(
            code: .unknownSession,
            message: "That terminal is no longer open on this Mac."
        )), to: client)
        return true
    }

    private func refuseNoRepository(_ client: UUID, _ server: BoardServer) -> Bool {
        server.send(.failure(WireFailure(
            code: .unreadablePath,
            message: "That board has no linked repository."
        )), to: client)
        return true
    }

    private func refusePath(_ path: String, _ client: UUID, _ server: BoardServer) -> Bool {
        server.send(.failure(WireFailure(
            code: .unreadablePath,
            message: "“\(path)” is not inside that repository."
        )), to: client)
        return true
    }
}

// MARK: - Mirroring

extension RepositoryService: TerminalSessionMirror {
    func session(_ session: TerminalSession, didProduce data: Data) {
        guard let server, let clients = watchers[session.id] else { return }
        let frame = ServerMessage.terminalOutput(sessionID: session.id.uuidString, data: data)
        for client in clients { server.send(frame, to: client) }
    }

    func sessionDidChangeState(_ session: TerminalSession) {
        guard let server, let clients = watchers[session.id] else { return }
        let frame = ServerMessage.terminalState(
            sessionID: session.id.uuidString,
            terminal: reference(to: session)
        )
        for client in clients { server.send(frame, to: client) }
    }
}

// MARK: - The setting

/// Whether paired phones may reach the terminal and the working copy.
///
/// Off until someone turns it on, and stored separately from whether the board
/// is shared at all: showing a colleague your board over the QR code should not
/// also hand them a shell. `UserDefaults.bool` answers false for a key that was
/// never written, which is the default we want and the reason there is no
/// registration step.
enum RemoteAccess {
    static let defaultsKey = "remoteRepositoryAccessEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
