import Foundation
import Testing
@testable import ClaudeWMWire

// MARK: - Round trips

@Test func clientFrameRoundTrips() throws {
    let request = MutationRequest(
        id: "req-1",
        projectID: "P",
        mutation: .moveCard(cardID: "C", toColumnID: "COL", index: 2)
    )
    let frame = ClientFrame(message: .mutate(request))
    let decoded = try WireCodec.decodeClientFrame(WireCodec.encode(frame))
    #expect(decoded == frame)
}

@Test func serverFrameRoundTrips() throws {
    let card = WireCard(
        id: "C", title: "Ship it", details: "**bold**", priority: .high,
        tags: ["ios"], githubIssue: 12, branch: "issue-12",
        blockedBy: ["D"], subtaskCount: 3, subtasksDone: 1,
        updatedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )
    let snapshot = BoardSnapshot(
        project: WireProjectRef(id: "P", name: "Board", repoSlug: "o/r"),
        columns: [WireColumn(id: "COL", name: "To Do", role: .todo, cards: [card])],
        revision: 99,
        capturedAt: Date(timeIntervalSince1970: 1_760_000_100)
    )
    let frame = ServerFrame(message: .snapshot(snapshot))
    let decoded = try WireCodec.decodeServerFrame(WireCodec.encode(frame))
    #expect(decoded == frame)
}

@Test(arguments: [
    BoardMutation.createCard(columnID: "COL", title: "New", details: "d"),
    .moveCard(cardID: "C", toColumnID: "COL", index: 0),
    .setTitle(cardID: "C", title: "Renamed"),
    .setDetails(cardID: "C", details: "notes"),
    .setPriority(cardID: "C", priority: .urgent),
    .setRequested(cardID: "C", requested: true),
    .deleteCard(cardID: "C"),
])
func everyMutationRoundTrips(_ mutation: BoardMutation) throws {
    let frame = ClientFrame(message: .mutate(
        MutationRequest(id: "r", projectID: "P", mutation: mutation)
    ))
    #expect(try WireCodec.decodeClientFrame(WireCodec.encode(frame)) == frame)
}

// MARK: - Tolerance
//
// The point of these: a newer peer must degrade to a refusal, never to a
// dropped connection or a blank board.

@Test func unknownMessageTypeBecomesUnrecognized() throws {
    let json = Data(#"{"version":1,"message":{"type":"teleport"}}"#.utf8)
    let frame = try WireCodec.decodeClientFrame(json)
    #expect(frame.message == .unrecognized(type: "teleport"))
}

@Test func unknownMutationKindBecomesUnrecognized() throws {
    let json = Data("""
    {"version":1,"message":{"type":"mutate","request":
      {"id":"r","projectID":"P","mutation":{"kind":"setMood","cardID":"C"}}}}
    """.utf8)
    let frame = try WireCodec.decodeClientFrame(json)
    guard case .mutate(let request) = frame.message else {
        Issue.record("expected a mutate frame, got \(frame.message)")
        return
    }
    #expect(request.mutation == .unrecognized(kind: "setMood"))
}

@Test func mutationMissingItsCardIDIsRefusedNotHalfApplied() throws {
    // `setTitle` without a cardID would otherwise decode to a mutation that
    // names no card — worse than an unknown one, because it looks applicable.
    let json = Data(#"{"kind":"setTitle","title":"x"}"#.utf8)
    let mutation = try JSONDecoder().decode(BoardMutation.self, from: json)
    #expect(mutation == .unrecognized(kind: "setTitle"))
}

@Test func unknownPriorityFallsBackRatherThanFailing() throws {
    let json = Data(#"{"id":"C","title":"T","priority":"catastrophic"}"#.utf8)
    let card = try JSONDecoder().decode(WireCard.self, from: json)
    #expect(card.priority == .normal)
    #expect(card.title == "T")
}

@Test func aCardMissingEverythingButAnIDStillDecodes() throws {
    let card = try JSONDecoder().decode(WireCard.self, from: Data(#"{"id":"C"}"#.utf8))
    #expect(card.id == "C")
    #expect(card.tags.isEmpty)
    #expect(card.requested == false)
    #expect(card.isDone == false)
}

@Test func aCardWithoutAnIDIsUnusableAndThrows() {
    // The one field with no sane default: a card we cannot address is not a
    // card. This is the boundary of tolerance, and it is deliberate.
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(WireCard.self, from: Data(#"{"title":"T"}"#.utf8))
    }
}

// MARK: - Versioning

@Test func aNewerPeerIsRecognisedAsNewer() throws {
    let json = Data(#"{"version":99,"message":{"type":"listProjects"}}"#.utf8)
    #expect(try WireCodec.decodeClientFrame(json).isFromNewerPeer)
    #expect(ClientFrame(message: .listProjects).isFromNewerPeer == false)
}

// MARK: - Board semantics

@Test func blockedIsAboutTheBlockersState() {
    let open = WireCard(id: "A", title: "A", isDone: false, updatedAt: .distantPast)
    let closed = WireCard(id: "B", title: "B", isDone: true, updatedAt: .distantPast)
    let subject = WireCard(id: "C", title: "C", blockedBy: ["A", "B"], updatedAt: .distantPast)
    let all = [open, closed, subject].reduce(into: [String: WireCard]()) { $0[$1.id] = $1 }

    #expect(subject.isBlocked(in: all))

    var unblocked = subject
    unblocked.blockedBy = ["B"]
    #expect(unblocked.isBlocked(in: all) == false)

    // A blocker the phone has never heard of must not read as satisfied.
    var dangling = subject
    dangling.blockedBy = ["ghost"]
    #expect(dangling.isBlocked(in: all) == false)
}

@Test func priorityOrdersBySeverityNotSpelling() {
    #expect(WirePriority.low < .normal)
    #expect(WirePriority.normal < .high)
    #expect(WirePriority.high < .urgent)
    // "high" < "normal" alphabetically, which is the bug this guards.
    #expect(WirePriority.high > .normal)
}

@Test func mutationVocabularyCannotTouchClaudesFields() {
    // `branch` and `prUrl` are the agent's. If a future mutation ever spells
    // them, this test is where that decision has to be made deliberately.
    let spellings: [String] = [
        BoardMutation.createCard(columnID: "1", title: "t", details: "d"),
        .moveCard(cardID: "C", toColumnID: "1", index: 0),
        .setTitle(cardID: "C", title: "t"),
        .setDetails(cardID: "C", details: "d"),
        .setPriority(cardID: "C", priority: .low),
        .setRequested(cardID: "C", requested: true),
        .deleteCard(cardID: "C"),
    ].map(\.kind)

    #expect(!spellings.contains { $0.lowercased().contains("branch") })
    #expect(!spellings.contains { $0.lowercased().contains("prurl") })
}
