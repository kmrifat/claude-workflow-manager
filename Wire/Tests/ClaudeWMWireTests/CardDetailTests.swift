import Foundation
import Testing
@testable import ClaudeWMWire

private func roundTrip(_ message: ServerMessage) throws -> ServerMessage {
    try WireCodec.decodeServerFrame(WireCodec.encode(ServerFrame(message: message))).message
}

private func roundTrip(_ message: ClientMessage) throws -> ClientMessage {
    try WireCodec.decodeClientFrame(WireCodec.encode(ClientFrame(message: message))).message
}

private func roundTrip(_ mutation: BoardMutation) throws -> BoardMutation {
    let request = MutationRequest(id: "R", projectID: "P", mutation: mutation)
    guard case .mutate(let decoded) = try roundTrip(.mutate(request)) else { throw CancellationError() }
    return decoded.mutation
}

private let moment = Date(timeIntervalSince1970: 1_790_000_000)

@Suite("Cards in full, Home and images")
struct CardDetailTests {

    @Test func everyNewClientMessageSurvivesTheWire() throws {
        let messages: [ClientMessage] = [
            .requestCard(projectID: "P", cardID: "C"),
            .requestOverview,
            .uploadChunk(WireUploadChunk(uploadID: "U", projectID: "P", cardID: "C", filename: "a.png",
                                         totalBytes: 3, offset: 0, data: Data([1, 2, 3]), isLast: true)),
            .requestAttachment(projectID: "P", attachmentID: "A", maxEdge: 600),
            .requestAttachment(projectID: "P", attachmentID: "A", maxEdge: nil),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message)
        }
    }

    @Test func everyNewServerMessageSurvivesTheWire() throws {
        let card = WireCard(id: "C", title: "Fix it", updatedAt: moment, imageCount: 2,
                            agentState: .working, agentDetail: "Editing a.swift")
        let detail = WireCardDetail(
            projectID: "P", card: card, columnID: "COL",
            subtasks: [WireSubtask(id: "S", title: "Draft", done: true)],
            activity: [WireActivity(id: "E", date: moment, actor: "Claude", tool: "update_card",
                                    summary: "Moved to In Progress", note: "on it")],
            attachments: [WireAttachmentRef(id: "A", name: "shot.png", contentType: "public.png",
                                            width: 800, height: 600, byteCount: 12345)],
            agentState: .working, agentName: "Claude", claimedAt: moment, createdAt: moment
        )
        let messages: [ServerMessage] = [
            .cardDetail(detail),
            .overview(WireOverview(agents: [WireQueueItem(projectID: "P", projectName: "Launch", cardID: "C",
                                                          title: "Fix it", columnName: "In Progress",
                                                          detail: "Editing a.swift", dueDate: moment)])),
            .uploadProgress(uploadID: "U", receivedBytes: 196_608),
            .uploadComplete(uploadID: "U", attachmentID: "A", reference: "![shot](attachment:A)"),
            .attachmentChunk(WireAttachmentChunk(attachmentID: "A", maxEdge: 600, contentType: "public.jpeg",
                                                 totalBytes: 2, offset: 0, data: Data([9, 9]), isLast: true)),
            .ack(requestID: "R", revision: 4, createdCardID: "NEW"),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message)
        }
    }

    @Test func everyNewMutationSurvivesTheWire() throws {
        let mutations: [BoardMutation] = [
            .setSubtask(cardID: "C", subtaskID: "S", done: true),
            .addSubtask(cardID: "C", title: "Write tests"),
            .deleteSubtask(cardID: "C", subtaskID: "S"),
            .addNote(cardID: "C", note: "Use the existing dialog"),
            .setDueDate(cardID: "C", dueDate: moment),
            .setDueDate(cardID: "C", dueDate: nil),
            .setOwner(cardID: "C", owner: "JD"),
            .setTags(cardID: "C", tags: ["ios", "v1"]),
        ]
        for mutation in mutations {
            #expect(try roundTrip(mutation) == mutation)
        }
    }

    @Test func clearingADueDateIsNotTheSameAsForgettingIt() throws {
        // Present-and-null clears; absent is a malformed request, refused
        // rather than read as "clear".
        let missing = Data(#"{"version":1,"message":{"type":"mutate","request":{"id":"R","projectID":"P","mutation":{"kind":"setDueDate","cardID":"C"}}}}"#.utf8)
        guard case .mutate(let request) = try WireCodec.decodeClientFrame(missing).message else {
            Issue.record("not a mutation"); return
        }
        #expect(request.mutation == .unrecognized(kind: "setDueDate"))
    }

    @Test func anOlderMacsAckAndCardsStillDecode() throws {
        let ack = Data(#"{"version":1,"message":{"type":"ack","requestID":"R","revision":3}}"#.utf8)
        #expect(try WireCodec.decodeServerFrame(ack).message == .ack(requestID: "R", revision: 3, createdCardID: nil))

        let card = try JSONDecoder().decode(WireCard.self, from: Data(#"{"id":"C","title":"Old"}"#.utf8))
        #expect(card.imageCount == 0 && card.agentState == nil && card.agentDetail == nil)

        let project = try JSONDecoder().decode(WireProjectRef.self, from: Data(#"{"id":"P","name":"Old"}"#.utf8))
        #expect(project.path == nil && project.totalCount == nil)
    }

    @Test func anOlderMacDeclinesTheNewRequestsRatherThanMisreadingThem() throws {
        // What an older Mac's decoder makes of a message it has never seen.
        let unknown = Data(#"{"version":1,"message":{"type":"requestFutureThing","projectID":"P"}}"#.utf8)
        #expect(try WireCodec.decodeClientFrame(unknown).message == .unrecognized(type: "requestFutureThing"))
    }

    // MARK: Pieces

    @Test func anImageIsCutIntoOrderedPiecesAndPutBackTogether() throws {
        let image = Data((0..<(WireImageTransfer.chunkSize * 2 + 100)).map { UInt8($0 % 251) })
        let pieces = WireImageTransfer.pieces(of: image)
        #expect(pieces.count == 3)
        #expect(pieces.last?.isLast == true && pieces.dropLast().allSatisfy { !$0.isLast })

        var assembler = WireImageTransfer.Assembler(expectedBytes: image.count)
        var whole: Data?
        for piece in pieces {
            whole = try assembler.add(offset: piece.offset, data: piece.data, isLast: piece.isLast)
        }
        #expect(whole == image)
    }

    @Test func aPieceOutOfOrderIsRefused() throws {
        let image = Data(repeating: 1, count: WireImageTransfer.chunkSize + 10)
        let pieces = WireImageTransfer.pieces(of: image)
        var assembler = WireImageTransfer.Assembler(expectedBytes: image.count)
        #expect(throws: WireImageTransfer.Assembler.Failure.outOfOrder) {
            try assembler.add(offset: pieces[1].offset, data: pieces[1].data, isLast: true)
        }
    }

    @Test func moreThanWasPromisedIsRefused() throws {
        var assembler = WireImageTransfer.Assembler(expectedBytes: 4)
        #expect(throws: WireImageTransfer.Assembler.Failure.tooLarge) {
            try assembler.add(offset: 0, data: Data(repeating: 0, count: 5), isLast: true)
        }
    }

    @Test func lessThanWasPromisedIsRefused() throws {
        var assembler = WireImageTransfer.Assembler(expectedBytes: 10)
        #expect(throws: WireImageTransfer.Assembler.Failure.sizeMismatch) {
            try assembler.add(offset: 0, data: Data(repeating: 0, count: 4), isLast: true)
        }
    }

    @Test func anEmptyImageIsStillOneLastPiece() {
        let pieces = WireImageTransfer.pieces(of: Data())
        #expect(pieces.count == 1 && pieces[0].isLast)
    }
}
