//
//  A real phone, a real Mac, over a real TLS-PSK socket.
//
//  Everything here is the app's own code — BoardServer, BoardService,
//  RepositoryService, TerminalSession, a real `zsh` on a real pty — with a
//  client built from the wire types the phone uses. Nothing is mocked, so a
//  drift between the two ends shows up as a failed check rather than as a bug
//  someone finds on a train.
//

import AppKit
import Foundation
import Network
import SwiftData
import ClaudeWMWire

// MARK: - Harness plumbing

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print(condition ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !condition { failures += 1 }
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// The phone's half: dial the endpoint, speak the wire, collect what comes back.
@MainActor
final class TestClient {
    private var connection: NWConnection?
    var received: [ServerMessage] = []
    private let queue = DispatchQueue(label: "loopback.client")

    func connect(port: UInt16, key: Data) {
        // The client must dial an `NWEndpoint.url`, not host+port: the upgrade
        // is an HTTP request that needs a path and a Host header. Host+port
        // completes the TLS handshake and *then* aborts with POSIX 53.
        let url = URL(string: "wss://127.0.0.1:\(port)/")!
        let connection = NWConnection(to: .url(url), using: BoardTransport.parameters(key: key))
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    func send(_ message: ClientMessage) {
        guard let connection, let data = try? WireCodec.encode(ClientFrame(message: message)) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }
            if let data, let frame = try? WireCodec.decodeServerFrame(data) {
                Task { @MainActor in self.received.append(frame.message) }
            }
            self.receive(on: connection)
        }
    }

    /// Waits for a message matching `predicate`, pumping the run loop.
    func waitFor(
        _ label: String,
        timeout: TimeInterval = 6,
        _ predicate: @escaping (ServerMessage) -> Bool
    ) -> ServerMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = received.first(where: predicate) { return match }
            pump(0.1)
        }
        return nil
    }

    func drop() { connection?.cancel() }
}

// MARK: - A repository to look at

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "loopback-repo-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try? "# Hello\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
try? FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
try? "let x = 1\n".write(to: root.appending(path: "Sources/main.swift"), atomically: true, encoding: .utf8)

// A secret outside the repository, and a symlink inside it that points at the
// secret's directory. String rules alone cannot catch this one.
let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "loopback-outside")
try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try? "TOP SECRET\n".write(to: outside.appending(path: "id_rsa"), atomically: true, encoding: .utf8)
try? FileManager.default.createSymbolicLink(
    at: root.appending(path: "escape"),
    withDestinationURL: outside
)

// MARK: - The Mac

let schema = Schema([Project.self, BoardColumn.self, WorkItem.self, TerminalCommand.self])
let container = try ModelContainer(
    for: schema,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
)

let outcome: Void = try MainActor.assumeIsolated {
    let context = ModelContext(container)

    let project = Project(name: "Loopback")
    project.repoPath = root.path
    context.insert(project)

    let command = TerminalCommand(name: "greeter", command: "echo READY_FROM_SAVED_COMMAND")
    command.project = project
    context.insert(command)
    try context.save()

    let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    let server = BoardServer()
    let service = BoardService(context: context, expectedToken: { key })
    let terminals = TerminalStateStore()
    service.attachRepositoryAccess(terminals: terminals)
    server.handler = service
    server.start(key: key, serviceName: "Loopback Harness")

    var port: UInt16 = 0
    for _ in 0..<50 {
        if case .running(let running) = server.state { port = running; break }
        pump(0.1)
    }
    guard port != 0 else {
        print("  FAIL server never started: \(server.state)")
        failures += 1
        return
    }
    print("Server on port \(port)")

    let projectID = project.uuid.uuidString
    let client = TestClient()
    client.connect(port: port, key: key)
    client.send(.hello(token: key.base64EncodedString(), clientName: "Harness"))
    guard client.waitFor("welcome", { if case .welcome = $0 { true } else { false } }) != nil else {
        print("  FAIL never got welcome — TLS or hello failed")
        failures += 1
        return
    }
    print("\n1. The gate is closed by default")

    RemoteAccess.isEnabled = false
    client.received.removeAll()
    client.send(.listTerminals(projectID: projectID))
    let refusal = client.waitFor("forbidden") {
        if case .failure(let failure) = $0 { failure.code == .forbidden } else { false }
    }
    check("a terminal request is refused while the setting is off", refusal != nil)
    check("nothing was listed anyway", !client.received.contains { $0.type == "terminals" })

    client.received.removeAll()
    client.send(.readFile(projectID: projectID, path: "README.md"))
    check(
        "a file request is refused too",
        client.waitFor("forbidden file") {
            if case .failure(let failure) = $0 { failure.code == .forbidden } else { false }
        } != nil
    )

    print("\n2. Turning it on takes effect on a live connection")

    RemoteAccess.isEnabled = true
    client.received.removeAll()
    client.send(.listTerminals(projectID: projectID))
    let listed = client.waitFor("terminals") { if case .terminals = $0 { true } else { false } }
    guard case .terminals(_, let refs)? = listed else {
        print("  FAIL no terminal list arrived")
        failures += 1
        return
    }
    check("the saved command is offered as a session", refs.contains { $0.title.contains("greeter") },
          "got \(refs.map(\.title))")
    check("and it is not running yet", refs.allSatisfy { !$0.isRunning })

    guard let session = refs.first else {
        print("  FAIL no session to attach to")
        failures += 1
        return
    }

    print("\n3. Attach, start, and watch a real shell")

    client.received.removeAll()
    client.send(.attachTerminal(projectID: projectID, sessionID: session.id))
    check(
        "the Mac answers with a screen to paint",
        client.waitFor("attached") { if case .terminalAttached = $0 { true } else { false } } != nil
    )

    client.send(.terminalAction(sessionID: session.id, action: .start))
    let started = client.waitFor("running") {
        if case .terminalState(_, let ref) = $0 { ref.isRunning } else { false }
    }
    check("starting it is reported back", started != nil)

    // The saved command is typed into the shell after it settles, so its output
    // is what proves the whole chain: pty → session → relay → socket → phone.
    var sawSavedCommand = false
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline, !sawSavedCommand {
        pump(0.2)
        let output = client.received.compactMap { message -> Data? in
            if case .terminalOutput(_, let data) = message { data } else { nil }
        }
        let text = output.reduce(into: Data()) { $0.append($1) }
        sawSavedCommand = String(decoding: text, as: UTF8.self).contains("READY_FROM_SAVED_COMMAND")
    }
    check("the saved command's output reached the phone", sawSavedCommand)

    print("\n4. Typing on the phone reaches the shell")

    client.received.removeAll()
    client.send(.terminalInput(
        sessionID: session.id,
        data: Data("echo TYPED_ON_PHONE\r".utf8)
    ))
    var sawTyped = false
    let typedDeadline = Date().addingTimeInterval(8)
    while Date() < typedDeadline, !sawTyped {
        pump(0.2)
        let text = client.received.compactMap { message -> Data? in
            if case .terminalOutput(_, let data) = message { data } else { nil }
        }.reduce(into: Data()) { $0.append($1) }
        // The echoed *result*, not the echoed keystrokes: the line discipline
        // echoes what was typed either way, so matching the command text alone
        // would pass without the shell ever running it.
        sawTyped = String(decoding: text, as: UTF8.self)
            .components(separatedBy: "TYPED_ON_PHONE").count > 2
    }
    check("the shell ran what the phone typed", sawTyped)

    print("\n5. Files, and the paths that must not be served")

    client.received.removeAll()
    client.send(.listDirectory(projectID: projectID, path: ""))
    let listing = client.waitFor("directory") { if case .directory = $0 { true } else { false } }
    guard case .directory(_, _, let entries)? = listing else {
        print("  FAIL no directory listing")
        failures += 1
        return
    }
    check("the repository root lists its files", entries.contains { $0.name == "README.md" })
    check("paths are repository-relative, never absolute",
          entries.allSatisfy { !$0.path.hasPrefix("/") }, "got \(entries.map(\.path))")

    client.received.removeAll()
    client.send(.readFile(projectID: projectID, path: "README.md"))
    let read = client.waitFor("file") { if case .fileContent = $0 { true } else { false } }
    if case .fileContent(_, _, .text(let text))? = read {
        check("a file comes back with its contents", text.contains("Hello"))
    } else {
        check("a file comes back with its contents", false, "got \(String(describing: read))")
    }

    for escape in ["../loopback-outside/id_rsa", "/etc/passwd", "escape/id_rsa", "Sources/../../loopback-outside/id_rsa"] {
        client.received.removeAll()
        client.send(.readFile(projectID: projectID, path: escape))
        let answer = client.waitFor("escape \(escape)", timeout: 3) {
            if case .failure = $0 { true } else if case .fileContent = $0 { true } else { false }
        }
        var refused = false
        if case .failure(let failure)? = answer, failure.code == .unreadablePath { refused = true }
        check("refuses “\(escape)”", refused, "got \(String(describing: answer))")
    }

    print("\n6. A phone that leaves stops being mirrored")

    client.drop()
    pump(1.0)
    // The session is still running on the Mac — dropping a phone must not kill
    // a dev server — but nothing is being sent to it any more.
    let stillRunning = terminals.session(UUID(uuidString: session.id)!)?.isRunning ?? false
    check("the shell outlives the phone", stillRunning)

    terminals.session(UUID(uuidString: session.id)!)?.stop()
    server.stop()
    RemoteAccess.isEnabled = false
    pump(0.5)
}

try? FileManager.default.removeItem(at: root)
try? FileManager.default.removeItem(at: outside)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
