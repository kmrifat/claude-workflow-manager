//
//  RepositoryAccessTests.swift
//  ClaudeWMWireTests
//
//  The frames a phone uses to reach a terminal and a working copy, and the path
//  rules that decide what it may name.
//

import Foundation
import Testing
@testable import ClaudeWMWire

@Suite("Repository access frames")
struct RepositoryAccessFrameTests {

    private func roundTrip(_ message: ClientMessage) throws -> ClientMessage {
        let data = try WireCodec.encode(ClientFrame(message: message))
        return try WireCodec.decodeClientFrame(data).message
    }

    private func roundTrip(_ message: ServerMessage) throws -> ServerMessage {
        let data = try WireCodec.encode(ServerFrame(message: message))
        return try WireCodec.decodeServerFrame(data).message
    }

    @Test("Every client message survives the wire")
    func clientMessages() throws {
        let messages: [ClientMessage] = [
            .listTerminals(projectID: "p1"),
            .attachTerminal(projectID: "p1", sessionID: "s1"),
            .detachTerminal(sessionID: "s1"),
            .terminalInput(sessionID: "s1", data: Data([0x03])),
            .terminalAction(sessionID: "s1", action: .restart),
            .listDirectory(projectID: "p1", path: "Sources/App"),
            .readFile(projectID: "p1", path: "README.md"),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message, "\(message.type) did not survive")
        }
    }

    @Test("Every server message survives the wire")
    func serverMessages() throws {
        let terminal = WireTerminalRef(
            id: "s1",
            title: "dev server",
            isRunning: true,
            isSavedCommand: true,
            status: "Running",
            cols: 120,
            rows: 30
        )
        let messages: [ServerMessage] = [
            .terminals(projectID: "p1", [terminal]),
            .terminalAttached(sessionID: "s1", terminal: terminal, replay: Data([0x1b, 0x5b, 0x41])),
            .terminalOutput(sessionID: "s1", data: Data("hello".utf8)),
            .terminalState(sessionID: "s1", terminal: terminal),
            .directory(projectID: "p1", path: "Sources", entries: [
                WireFileNode(name: "App", path: "Sources/App", isDirectory: true, size: nil),
                WireFileNode(name: "main.swift", path: "Sources/main.swift", isDirectory: false, size: 42),
            ]),
            .fileContent(projectID: "p1", path: "README.md", content: .text("# Title")),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message, "\(message.type) did not survive")
        }
    }

    @Test("Terminal bytes survive exactly, including NUL and high bytes")
    func binarySafety() throws {
        // Output is arbitrary bytes: escape sequences, UTF-8 fragments split
        // across reads, and NULs. Base64 in JSON has to carry all of it.
        let bytes = Data((0...255).map { UInt8($0) })
        let decoded = try roundTrip(ServerMessage.terminalOutput(sessionID: "s1", data: bytes))
        guard case .terminalOutput(_, let received) = decoded else {
            Issue.record("wrong case: \(decoded.type)")
            return
        }
        #expect(received == bytes)
    }

    @Test("Every file content case survives")
    func fileContents() throws {
        let cases: [WireFileContent] = [
            .text("line\n"),
            .image(Data([0x89, 0x50, 0x4e, 0x47])),
            .binary(size: 9000),
            .tooLarge(size: 3_000_000),
            .unreadable("No such file."),
        ]
        for content in cases {
            let message = ServerMessage.fileContent(projectID: "p", path: "f", content: content)
            #expect(try roundTrip(message) == message, "\(content.kind) did not survive")
        }
    }

    @Test("An old Mac refuses these rather than misreading them")
    func unknownToAnOlderPeer() throws {
        // The forward-compatibility claim in WireMessage: a message type a peer
        // does not know decodes to `unrecognized`, which is answered with a
        // failure. Simulated by decoding a type this build will never add.
        let json = #"{"version":1,"message":{"type":"summonDaemon"}}"#
        let frame = try WireCodec.decodeClientFrame(Data(json.utf8))
        #expect(frame.message == .unrecognized(type: "summonDaemon"))
    }

    @Test("A refusal names why, and the codes stay distinct")
    func failureCodes() throws {
        for code in [WireFailure.Code.forbidden, .unknownSession, .unreadablePath] {
            let message = ServerMessage.failure(WireFailure(code: code, message: "no"))
            #expect(try roundTrip(message) == message)
        }
        // An older phone decoding a code it has never heard of must still show
        // the message rather than dropping the frame.
        let json = #"{"version":1,"message":{"type":"failure","failure":{"code":"tuesday","message":"Not today."}}}"#
        let frame = try WireCodec.decodeServerFrame(Data(json.utf8))
        guard case .failure(let failure) = frame.message else {
            Issue.record("wrong case")
            return
        }
        #expect(failure.code == .rejected)
        #expect(failure.message == "Not today.")
    }
}

@Suite("Repository paths")
struct RepositoryPathTests {

    @Test("The root is spelled several ways and they all mean the root")
    func root() {
        #expect(RepositoryPath.sanitize("") == "")
        #expect(RepositoryPath.sanitize(".") == "")
        #expect(RepositoryPath.sanitize("/") == nil)
    }

    @Test("Ordinary paths pass through, tidied")
    func ordinary() {
        #expect(RepositoryPath.sanitize("Sources/App/main.swift") == "Sources/App/main.swift")
        #expect(RepositoryPath.sanitize("Sources//App/") == "Sources/App")
        #expect(RepositoryPath.sanitize("./Sources/./App") == "Sources/App")
    }

    @Test("Escapes are refused, not resolved")
    func escapes() {
        #expect(RepositoryPath.sanitize("../secrets") == nil)
        #expect(RepositoryPath.sanitize("Sources/../../etc/passwd") == nil)
        // The one that beats a naive prefix check: collapsing first turns this
        // into `../b`, but a check run before collapsing sees a leading `a`.
        #expect(RepositoryPath.sanitize("a/../../b") == nil)
        #expect(RepositoryPath.sanitize("/etc/passwd") == nil)
        #expect(RepositoryPath.sanitize("~/.ssh/id_rsa") == nil)
    }

    @Test("A dotfile is not an escape")
    func dotfiles() {
        // `.env` and `.github` start with a dot and are perfectly ordinary; only
        // exactly `..` is a parent reference.
        #expect(RepositoryPath.sanitize(".github/workflows/ci.yml") == ".github/workflows/ci.yml")
        #expect(RepositoryPath.sanitize("..env") == "..env")
    }

    @Test("Relative paths survive the directory trailing slash")
    func trailingSlash() {
        // The bug this exists to prevent: a root that ends in "/" makes every
        // child fail containment, which reads as a path escape.
        #expect(RepositoryPath.relative("/repo/Sources/main.swift", to: "/repo/") == "Sources/main.swift")
        #expect(RepositoryPath.relative("/repo/Sources/main.swift", to: "/repo") == "Sources/main.swift")
        #expect(RepositoryPath.relative("/repo", to: "/repo") == "")
        #expect(RepositoryPath.relative("/repo-other/x", to: "/repo") == nil)
        #expect(RepositoryPath.relative("/elsewhere/x", to: "/repo") == nil)
    }
}
