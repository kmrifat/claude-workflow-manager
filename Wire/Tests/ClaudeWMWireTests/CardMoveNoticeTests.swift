import Foundation
import Testing
@testable import ClaudeWMWire

private func board(_ columns: [(String, [String])], project: String = "Board") -> BoardSnapshot {
    BoardSnapshot(
        project: WireProjectRef(id: "P", name: project),
        columns: columns.map { name, titles in
            WireColumn(id: name, name: name, cards: titles.map {
                WireCard(id: $0, title: $0, updatedAt: .distantPast)
            })
        },
        revision: 0,
        capturedAt: .distantPast
    )
}

@Test func aCardChangingColumnIsAMove() {
    let before = board([("To Do", ["a", "b"]), ("Done", [])])
    let after  = board([("To Do", ["b"]),      ("Done", ["a"])])
    let moves = after.moves(since: before, origin: .claude)

    #expect(moves.count == 1)
    #expect(moves.first?.cardTitle == "a")
    #expect(moves.first?.fromColumn == "To Do")
    #expect(moves.first?.toColumn == "Done")
}

@Test func reorderingWithinAColumnIsNotAMove() {
    // The single most likely source of spurious notifications: a drag that
    // changes order but not column, which happens constantly.
    let before = board([("To Do", ["a", "b", "c"])])
    let after  = board([("To Do", ["c", "a", "b"])])
    #expect(after.moves(since: before, origin: .mac).isEmpty)
}

@Test func aNewCardIsNotAMove() {
    let before = board([("To Do", ["a"])])
    let after  = board([("To Do", ["a", "brand-new"])])
    #expect(after.moves(since: before, origin: .phone).isEmpty)
}

@Test func aDeletedCardIsNotAMove() {
    let before = board([("To Do", ["a", "b"])])
    let after  = board([("To Do", ["a"])])
    #expect(after.moves(since: before, origin: .mac).isEmpty)
}

@Test func yourOwnMoveIsIgnored() {
    let before = board([("To Do", ["a", "b"]), ("Done", [])])
    let after  = board([("To Do", []),         ("Done", ["a", "b"])])

    #expect(after.moves(since: before, origin: .mac).count == 2)
    // Having dragged `a` yourself, you should hear only about `b`.
    let others = after.moves(since: before, ignoring: ["a"], origin: .mac)
    #expect(others.count == 1)
    #expect(others.first?.cardTitle == "b")
}

@Test func aRenamedColumnDoesNotLookLikeEveryCardMoving() {
    // Columns are matched by name, so renaming one would report every card in
    // it as moved — a rename storm of notifications. This pins the behaviour so
    // the decision is deliberate if it ever changes.
    let before = board([("To Do", ["a", "b", "c"])])
    let after  = board([("Backlog", ["a", "b", "c"])])
    #expect(after.moves(since: before, origin: .mac).count == 3)
}

// MARK: - Wording

@Test func theNoticeLeadsWithTheCardNotTheApp() {
    let notice = CardMoveNotice(
        cardTitle: "Ship the phone client",
        fromColumn: "In Progress", toColumn: "Review",
        projectName: "Claude WM", origin: .claude
    )
    #expect(notice.title == "Ship the phone client")
    #expect(notice.body == "In Progress → Review · by Claude")
    #expect(notice.subtitle == "Claude WM")
}

@Test func aMoveWithNoKnownOriginColumnStillReads() {
    let notice = CardMoveNotice(
        cardTitle: "x", fromColumn: nil, toColumn: "Done",
        projectName: "P", origin: .phone
    )
    #expect(notice.body == "Moved to Done · by your phone")
}

@Test func anUntitledCardDoesNotProduceABlankBanner() {
    let notice = CardMoveNotice(
        cardTitle: "", fromColumn: "A", toColumn: "B",
        projectName: "P", origin: .mac
    )
    #expect(notice.title == "Untitled card")
}

@Test func repeatedMovesOfOneCardCoalesce() {
    // A stable identifier per card means the newest banner replaces the last,
    // rather than three stale ones stacking up while an agent works.
    let first = CardMoveNotice(cardTitle: "x", fromColumn: "A", toColumn: "B",
                               projectName: "P", origin: .claude)
    let second = CardMoveNotice(cardTitle: "x", fromColumn: "B", toColumn: "C",
                                projectName: "P", origin: .claude)
    #expect(first.identifier == second.identifier)
    #expect(first.threadIdentifier == second.threadIdentifier)

    let elsewhere = CardMoveNotice(cardTitle: "x", fromColumn: "A", toColumn: "B",
                                   projectName: "Other", origin: .claude)
    #expect(elsewhere.identifier != first.identifier)
}
