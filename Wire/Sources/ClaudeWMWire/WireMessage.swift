//
//  WireMessage.swift
//  ClaudeWMWire
//
//  The frames themselves. One WebSocket carries every message, so each frame
//  names its own type; there are no paths and no methods, because there is no
//  HTTP here to have them.
//
//  Both directions decode unknown message types into an `unrecognized` case
//  rather than throwing. Dropping the connection on an unknown verb is the worst
//  available failure: to the user it looks exactly like the Mac going to sleep.
//

import Foundation

// MARK: - Phone to Mac

public enum ClientMessage: Sendable, Equatable {
    /// First frame on a connection. The token is checked before anything else
    /// is honoured; `name` is only ever shown to the user on the Mac, so they
    /// can see which phone is connected.
    case hello(token: String, clientName: String)
    /// Which boards exist, so the phone can offer a choice.
    case listProjects
    /// Full board. `haveRevision` lets the Mac answer "nothing changed" instead
    /// of resending a board the phone already has.
    case requestSnapshot(projectID: String, haveRevision: Int?)
    case mutate(MutationRequest)
    /// The phone's APNs device token, so the Mac can reach it while it is
    /// asleep. `deviceID` is stable across launches and reinstalls where the
    /// token is not — it is what lets the Mac recognise "this phone" and stop
    /// pushing to a token that has been replaced.
    ///
    /// Adding a message type does not bump `WireProtocol.version`: an older Mac
    /// decodes this as `unrecognized` and answers with a refusal, which is
    /// exactly the tolerance that exists for it. A version bump is for changes
    /// an old peer would *misread*, not ones it can decline.
    case registerPush(deviceID: String, token: String)

    // MARK: Terminal and files
    //
    // Every one of these is refused unless the Mac's owner enabled repository
    // access — see `RepositoryAccess.swift`. They are listed after the board
    // messages because that is what they are: an addition a Mac may decline,
    // not a new baseline.

    case listTerminals(projectID: String)
    /// Start receiving this session's output. The Mac answers with
    /// `terminalAttached`, which carries enough recent output to paint a screen.
    case attachTerminal(projectID: String, sessionID: String)
    case detachTerminal(sessionID: String)
    /// Keystrokes, already encoded — arrows as `ESC[A`, Ctrl-C as `0x03`. The
    /// phone's emulator does that encoding, exactly as the Mac's does, so this
    /// carries bytes rather than a description of a key.
    case terminalInput(sessionID: String, data: Data)
    case terminalAction(sessionID: String, action: WireTerminalAction)
    /// `path` is repository-relative; "" is the root.
    case listDirectory(projectID: String, path: String)
    case readFile(projectID: String, path: String)

    // MARK: Cards in full, Home, and images
    //
    // Additive, like the terminal messages: an older Mac answers these as
    // unrecognised, and the phone shows what it can without them.

    /// One card with its subtasks, activity and images. Answered by
    /// `cardDetail`.
    case requestCard(projectID: String, cardID: String)
    /// The three smart lists. Answered by `overview`.
    case requestOverview
    /// A piece of an image for a card; see `WireUploadChunk`.
    case uploadChunk(WireUploadChunk)
    /// An image by id, scaled to fit `maxEdge` pixels (nil for full size).
    /// Answered by `attachmentChunk`s.
    case requestAttachment(projectID: String, attachmentID: String, maxEdge: Int?)

    case unrecognized(type: String)

    public var type: String {
        switch self {
        case .hello:            "hello"
        case .listProjects:     "listProjects"
        case .requestSnapshot:  "requestSnapshot"
        case .mutate:           "mutate"
        case .registerPush:     "registerPush"
        case .listTerminals:    "listTerminals"
        case .attachTerminal:   "attachTerminal"
        case .detachTerminal:   "detachTerminal"
        case .terminalInput:    "terminalInput"
        case .terminalAction:   "terminalAction"
        case .listDirectory:    "listDirectory"
        case .readFile:         "readFile"
        case .requestCard:      "requestCard"
        case .requestOverview:  "requestOverview"
        case .uploadChunk:      "uploadChunk"
        case .requestAttachment: "requestAttachment"
        case .unrecognized(let type): type
        }
    }
}

// MARK: - Mac to phone

public enum ServerMessage: Sendable, Equatable {
    /// `relayURL` is where the Mac can be reached through its Cloudflare
    /// Tunnel right now, if it has one. A quick tunnel's address changes every
    /// time it starts, so a phone that connects at home learns the new one
    /// here rather than having to scan a new code. Optional, so an older phone
    /// simply ignores it.
    case welcome(serverName: String, relayURL: String? = nil)
    case projects([WireProjectRef])
    case snapshot(BoardSnapshot)
    /// The board moved. Carries the new revision only — the phone decides
    /// whether it needs the board, which keeps an idle phone cheap.
    case event(projectID: String, revision: Int)
    /// `createdCardID` answers a `createCard`: the Mac mints card ids, and a
    /// phone that wants to attach images to the card it just created needs to
    /// know which one that was.
    case ack(requestID: String, revision: Int, createdCardID: String? = nil)
    case failure(WireFailure)

    // MARK: Terminal and files

    case terminals(projectID: String, [WireTerminalRef])
    /// Answers `attachTerminal`. `replay` is raw pty output — the same bytes the
    /// Mac's emulator consumed — so the phone paints an identical screen by
    /// feeding it to an emulator of its own, colours and cursor moves included.
    /// A dump of the *rendered* text was the alternative and loses both.
    case terminalAttached(sessionID: String, terminal: WireTerminalRef, replay: Data)
    case terminalOutput(sessionID: String, data: Data)
    /// The session started, exited or was resized. Sent unprompted, so a phone
    /// watching a dev server sees it die without asking.
    case terminalState(sessionID: String, terminal: WireTerminalRef)
    case directory(projectID: String, path: String, entries: [WireFileNode])
    case fileContent(projectID: String, path: String, content: WireFileContent)

    // MARK: Cards in full, Home, and images

    case cardDetail(WireCardDetail)
    case overview(WireOverview)
    /// How much of an upload has arrived — the phone's progress bar.
    case uploadProgress(uploadID: String, receivedBytes: Int)
    /// The image is stored on the card, and `reference` is what was added to
    /// its notes.
    case uploadComplete(uploadID: String, attachmentID: String, reference: String)
    case attachmentChunk(WireAttachmentChunk)

    case unrecognized(type: String)

    public var type: String {
        switch self {
        case .welcome:          "welcome"
        case .projects:         "projects"
        case .snapshot:         "snapshot"
        case .event:            "event"
        case .ack:              "ack"
        case .failure:          "failure"
        case .terminals:        "terminals"
        case .terminalAttached: "terminalAttached"
        case .terminalOutput:   "terminalOutput"
        case .terminalState:    "terminalState"
        case .directory:        "directory"
        case .fileContent:      "fileContent"
        case .cardDetail:       "cardDetail"
        case .overview:         "overview"
        case .uploadProgress:   "uploadProgress"
        case .uploadComplete:   "uploadComplete"
        case .attachmentChunk:  "attachmentChunk"
        case .unrecognized(let type): type
        }
    }
}

public struct WireFailure: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case unauthorized
        case unknownProject
        case unknownCard
        case unsupportedMutation
        case versionMismatch
        case rejected
        /// Repository access is switched off on the Mac. Distinct from
        /// `unauthorized`, which means the device is not paired at all: one is
        /// fixed by a toggle, the other by pairing again, and a phone that
        /// confused them would send its owner to the wrong screen.
        case forbidden
        case unknownSession
        case unreadablePath
    }

    /// Present when the failure answers a specific `MutationRequest`.
    public var requestID: String?
    public var code: Code
    /// Shown to the user. Written for a person holding a phone, not for a log.
    public var message: String

    public init(requestID: String? = nil, code: Code, message: String) {
        self.requestID = requestID
        self.code = code
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)
        code = (try? container.decode(Code.self, forKey: .code)) ?? .rejected
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
    }
}

// MARK: - Envelopes

/// Wraps every frame with the protocol version.
///
/// The version sits on the envelope rather than inside each message so that a
/// mismatch can be answered without decoding a body this build may not
/// understand.
public struct ClientFrame: Codable, Sendable, Equatable {
    public var version: Int
    public var message: ClientMessage

    public init(version: Int = WireProtocol.version, message: ClientMessage) {
        self.version = version
        self.message = message
    }

    /// See `WireProtocol.version`: a newer peer is neither applied nor answered
    /// in the old format.
    public var isFromNewerPeer: Bool { version > WireProtocol.version }
}

public struct ServerFrame: Codable, Sendable, Equatable {
    public var version: Int
    public var message: ServerMessage

    public init(version: Int = WireProtocol.version, message: ServerMessage) {
        self.version = version
        self.message = message
    }

    public var isFromNewerPeer: Bool { version > WireProtocol.version }
}

// MARK: - Codec

public enum WireCodec {
    public static func encode(_ frame: ClientFrame) throws -> Data { try encoder.encode(frame) }
    public static func encode(_ frame: ServerFrame) throws -> Data { try encoder.encode(frame) }
    public static func decodeClientFrame(_ data: Data) throws -> ClientFrame {
        try decoder.decode(ClientFrame.self, from: data)
    }
    public static func decodeServerFrame(_ data: Data) throws -> ServerFrame {
        try decoder.decode(ServerFrame.self, from: data)
    }

    /// ISO-8601 to match `.taskboard/tasks.json`, so a date means the same thing
    /// everywhere in this product. `sortedKeys` because a stable byte order
    /// makes frames diffable in a log and tests independent of dictionary order.
    ///
    /// **Wire timestamps are second-resolution.** Foundation's `.iso8601`
    /// strategy emits no fractional part, so a `Date` that goes out at
    /// `…:37.600` comes back as `…:37`. That is fine for everything here — a
    /// card's `updatedAt` is shown to a person — but it means a decoded
    /// snapshot is *not* `==` to the one that was encoded, and anything
    /// comparing snapshots must use `revision` rather than equality. Adding
    /// fractional seconds was rejected: it would put a second date spelling
    /// into a product whose other timestamps a human hand-edits.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Message coding

private enum MessageKeys: String, CodingKey {
    case type, token, clientName, serverName, projectID, haveRevision
    case request, projects, snapshot, revision, requestID, failure
    case deviceID
    case sessionID, data, action, replay, terminal, terminals
    case path, entries, content
    case relayURL
    case cardID, maxEdge, chunk, detail, overview, uploadID, receivedBytes, attachmentID, reference
    case createdCardID
}

extension ClientMessage: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .hello(let token, let clientName):
            try container.encode(token, forKey: .token)
            try container.encode(clientName, forKey: .clientName)
        case .listProjects, .unrecognized:
            break
        case .requestSnapshot(let projectID, let haveRevision):
            try container.encode(projectID, forKey: .projectID)
            try container.encodeIfPresent(haveRevision, forKey: .haveRevision)
        case .mutate(let request):
            try container.encode(request, forKey: .request)
        case .registerPush(let deviceID, let token):
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(token, forKey: .token)
        case .listTerminals(let projectID):
            try container.encode(projectID, forKey: .projectID)
        case .attachTerminal(let projectID, let sessionID):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(sessionID, forKey: .sessionID)
        case .detachTerminal(let sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case .terminalInput(let sessionID, let data):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(data, forKey: .data)
        case .terminalAction(let sessionID, let action):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(action, forKey: .action)
        case .listDirectory(let projectID, let path):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(path, forKey: .path)
        case .readFile(let projectID, let path):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(path, forKey: .path)
        case .requestCard(let projectID, let cardID):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(cardID, forKey: .cardID)
        case .requestOverview:
            break
        case .uploadChunk(let chunk):
            try container.encode(chunk, forKey: .chunk)
        case .requestAttachment(let projectID, let attachmentID, let maxEdge):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(attachmentID, forKey: .attachmentID)
            try container.encodeIfPresent(maxEdge, forKey: .maxEdge)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            guard let token = try? container.decode(String.self, forKey: .token) else { break }
            self = .hello(
                token: token,
                clientName: (try? container.decode(String.self, forKey: .clientName)) ?? "Unknown device"
            )
            return
        case "listProjects":
            self = .listProjects
            return
        case "requestSnapshot":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .requestSnapshot(
                projectID: projectID,
                haveRevision: try? container.decodeIfPresent(Int.self, forKey: .haveRevision)
            )
            return
        case "mutate":
            guard let request = try? container.decode(MutationRequest.self, forKey: .request) else { break }
            self = .mutate(request)
            return
        case "registerPush":
            guard let deviceID = try? container.decode(String.self, forKey: .deviceID),
                  let token = try? container.decode(String.self, forKey: .token)
            else { break }
            self = .registerPush(deviceID: deviceID, token: token)
            return
        case "listTerminals":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .listTerminals(projectID: projectID)
            return
        case "attachTerminal":
            guard let projectID = try? container.decode(String.self, forKey: .projectID),
                  let sessionID = try? container.decode(String.self, forKey: .sessionID)
            else { break }
            self = .attachTerminal(projectID: projectID, sessionID: sessionID)
            return
        case "detachTerminal":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID) else { break }
            self = .detachTerminal(sessionID: sessionID)
            return
        case "terminalInput":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID),
                  let data = try? container.decode(Data.self, forKey: .data)
            else { break }
            self = .terminalInput(sessionID: sessionID, data: data)
            return
        case "terminalAction":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID),
                  let action = try? container.decode(WireTerminalAction.self, forKey: .action)
            else { break }
            self = .terminalAction(sessionID: sessionID, action: action)
            return
        case "listDirectory":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .listDirectory(
                projectID: projectID,
                path: (try? container.decode(String.self, forKey: .path)) ?? ""
            )
            return
        case "readFile":
            guard let projectID = try? container.decode(String.self, forKey: .projectID),
                  let path = try? container.decode(String.self, forKey: .path)
            else { break }
            self = .readFile(projectID: projectID, path: path)
            return
        case "requestCard":
            guard let projectID = try? container.decode(String.self, forKey: .projectID),
                  let cardID = try? container.decode(String.self, forKey: .cardID)
            else { break }
            self = .requestCard(projectID: projectID, cardID: cardID)
            return
        case "requestOverview":
            self = .requestOverview
            return
        case "uploadChunk":
            guard let chunk = try? container.decode(WireUploadChunk.self, forKey: .chunk) else { break }
            self = .uploadChunk(chunk)
            return
        case "requestAttachment":
            guard let projectID = try? container.decode(String.self, forKey: .projectID),
                  let attachmentID = try? container.decode(String.self, forKey: .attachmentID)
            else { break }
            self = .requestAttachment(
                projectID: projectID,
                attachmentID: attachmentID,
                maxEdge: try? container.decodeIfPresent(Int.self, forKey: .maxEdge)
            )
            return
        default:
            break
        }
        self = .unrecognized(type: type)
    }
}

extension ServerMessage: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .welcome(let serverName, let relayURL):
            try container.encode(serverName, forKey: .serverName)
            try container.encodeIfPresent(relayURL, forKey: .relayURL)
        case .projects(let projects):
            try container.encode(projects, forKey: .projects)
        case .snapshot(let snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case .event(let projectID, let revision):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(revision, forKey: .revision)
        case .ack(let requestID, let revision, let createdCardID):
            try container.encode(requestID, forKey: .requestID)
            try container.encode(revision, forKey: .revision)
            try container.encodeIfPresent(createdCardID, forKey: .createdCardID)
        case .failure(let failure):
            try container.encode(failure, forKey: .failure)
        case .terminals(let projectID, let terminals):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(terminals, forKey: .terminals)
        case .terminalAttached(let sessionID, let terminal, let replay):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(terminal, forKey: .terminal)
            try container.encode(replay, forKey: .replay)
        case .terminalOutput(let sessionID, let data):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(data, forKey: .data)
        case .terminalState(let sessionID, let terminal):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(terminal, forKey: .terminal)
        case .directory(let projectID, let path, let entries):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(path, forKey: .path)
            try container.encode(entries, forKey: .entries)
        case .fileContent(let projectID, let path, let content):
            try container.encode(projectID, forKey: .projectID)
            try container.encode(path, forKey: .path)
            try container.encode(content, forKey: .content)
        case .cardDetail(let detail):
            try container.encode(detail, forKey: .detail)
        case .overview(let overview):
            try container.encode(overview, forKey: .overview)
        case .uploadProgress(let uploadID, let receivedBytes):
            try container.encode(uploadID, forKey: .uploadID)
            try container.encode(receivedBytes, forKey: .receivedBytes)
        case .uploadComplete(let uploadID, let attachmentID, let reference):
            try container.encode(uploadID, forKey: .uploadID)
            try container.encode(attachmentID, forKey: .attachmentID)
            try container.encode(reference, forKey: .reference)
        case .attachmentChunk(let chunk):
            try container.encode(chunk, forKey: .chunk)
        case .unrecognized:
            break
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                serverName: (try? container.decode(String.self, forKey: .serverName)) ?? "",
                relayURL: try? container.decode(String.self, forKey: .relayURL)
            )
            return
        case "projects":
            self = .projects((try? container.decode([WireProjectRef].self, forKey: .projects)) ?? [])
            return
        case "snapshot":
            guard let snapshot = try? container.decode(BoardSnapshot.self, forKey: .snapshot) else { break }
            self = .snapshot(snapshot)
            return
        case "event":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .event(
                projectID: projectID,
                revision: (try? container.decode(Int.self, forKey: .revision)) ?? 0
            )
            return
        case "ack":
            guard let requestID = try? container.decode(String.self, forKey: .requestID) else { break }
            self = .ack(
                requestID: requestID,
                revision: (try? container.decode(Int.self, forKey: .revision)) ?? 0,
                createdCardID: try? container.decodeIfPresent(String.self, forKey: .createdCardID)
            )
            return
        case "failure":
            guard let failure = try? container.decode(WireFailure.self, forKey: .failure) else { break }
            self = .failure(failure)
            return
        case "terminals":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .terminals(
                projectID: projectID,
                (try? container.decode([WireTerminalRef].self, forKey: .terminals)) ?? []
            )
            return
        case "terminalAttached":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID),
                  let terminal = try? container.decode(WireTerminalRef.self, forKey: .terminal)
            else { break }
            // A missing replay is an empty screen, not a broken frame — a session
            // that has produced no output yet is the ordinary case.
            self = .terminalAttached(
                sessionID: sessionID,
                terminal: terminal,
                replay: (try? container.decode(Data.self, forKey: .replay)) ?? Data()
            )
            return
        case "terminalOutput":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID),
                  let data = try? container.decode(Data.self, forKey: .data)
            else { break }
            self = .terminalOutput(sessionID: sessionID, data: data)
            return
        case "terminalState":
            guard let sessionID = try? container.decode(String.self, forKey: .sessionID),
                  let terminal = try? container.decode(WireTerminalRef.self, forKey: .terminal)
            else { break }
            self = .terminalState(sessionID: sessionID, terminal: terminal)
            return
        case "directory":
            guard let projectID = try? container.decode(String.self, forKey: .projectID) else { break }
            self = .directory(
                projectID: projectID,
                path: (try? container.decode(String.self, forKey: .path)) ?? "",
                entries: (try? container.decode([WireFileNode].self, forKey: .entries)) ?? []
            )
            return
        case "fileContent":
            guard let projectID = try? container.decode(String.self, forKey: .projectID),
                  let path = try? container.decode(String.self, forKey: .path),
                  let content = try? container.decode(WireFileContent.self, forKey: .content)
            else { break }
            self = .fileContent(projectID: projectID, path: path, content: content)
            return
        case "cardDetail":
            guard let detail = try? container.decode(WireCardDetail.self, forKey: .detail) else { break }
            self = .cardDetail(detail)
            return
        case "overview":
            self = .overview((try? container.decode(WireOverview.self, forKey: .overview)) ?? WireOverview())
            return
        case "uploadProgress":
            guard let uploadID = try? container.decode(String.self, forKey: .uploadID) else { break }
            self = .uploadProgress(
                uploadID: uploadID,
                receivedBytes: (try? container.decode(Int.self, forKey: .receivedBytes)) ?? 0
            )
            return
        case "uploadComplete":
            guard let uploadID = try? container.decode(String.self, forKey: .uploadID),
                  let attachmentID = try? container.decode(String.self, forKey: .attachmentID),
                  let reference = try? container.decode(String.self, forKey: .reference)
            else { break }
            self = .uploadComplete(uploadID: uploadID, attachmentID: attachmentID, reference: reference)
            return
        case "attachmentChunk":
            guard let chunk = try? container.decode(WireAttachmentChunk.self, forKey: .chunk) else { break }
            self = .attachmentChunk(chunk)
            return
        default:
            break
        }
        self = .unrecognized(type: type)
    }
}
