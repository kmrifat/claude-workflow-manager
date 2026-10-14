//
//  KeyboardNavigation.swift
//  workflow-manager
//
//  Where the arrow keys go, worked out without a view: a board is a row of
//  lanes, the sidebar a flattened tree. Kept pure because key events cannot be
//  synthesised headlessly here, so these rules are the part that can be
//  checked without a person at the keyboard.
//

import Foundation

// MARK: - Board

/// A board as the keyboard sees it: lanes left to right, each holding the
/// cards it offers, top to bottom. Cards a filter dims are left out, so the
/// arrows skip what the eye is being told to skip.
enum BoardNavigation {
    struct Position: Equatable {
        var lane: Int
        var row: Int
    }

    static func locate<ID: Equatable>(_ id: ID?, in lanes: [[ID]]) -> Position? {
        guard let id else { return nil }
        for (lane, cards) in lanes.enumerated() {
            if let row = cards.firstIndex(of: id) { return Position(lane: lane, row: row) }
        }
        return nil
    }

    /// The first card on the board: where an arrow key lands when nothing is
    /// selected.
    static func first<ID>(in lanes: [[ID]]) -> ID? {
        lanes.first { !$0.isEmpty }?.first
    }

    /// The card above or below, or nil at either end of the lane — the
    /// selection stays put rather than wrapping into another lane.
    static func vertical<ID>(from position: Position, by delta: Int, in lanes: [[ID]]) -> ID? {
        let cards = lanes[position.lane]
        let row = position.row + delta
        return cards.indices.contains(row) ? cards[row] : nil
    }

    /// The card at the same height in the nearest lane that has any, or nil
    /// at the board's edge. Empty lanes are stepped over: landing on nothing
    /// would leave the selection somewhere the eye cannot see it.
    static func horizontal<ID>(from position: Position, by delta: Int, in lanes: [[ID]]) -> ID? {
        var lane = position.lane + delta
        while lanes.indices.contains(lane), lanes[lane].isEmpty { lane += delta }
        guard lanes.indices.contains(lane) else { return nil }
        let cards = lanes[lane]
        return cards[min(position.row, cards.count - 1)]
    }
}

// MARK: - Tree

/// One visible row of a tree, in display order.
struct TreeEntry<Node: Hashable> {
    let node: Node
    /// The row it is nested under, or nil at the top level.
    let parent: Node?
    /// What type-to-select matches against.
    let title: String
    /// nil for a row that does not fold; otherwise whether it is open.
    let isOpen: Bool?
}

/// Finder's outline rules: → opens, then steps in; ← closes, then steps out.
enum TreeNavigation {
    enum Action<Node: Hashable>: Equatable {
        case moveTo(Node)
        case open(Node)
        case close(Node)
        case none
    }

    /// The row `delta` steps away, clamped to the ends. With no current row,
    /// the first.
    static func step<Node>(_ entries: [TreeEntry<Node>], from current: Node?, by delta: Int) -> Node? {
        guard !entries.isEmpty else { return nil }
        guard let index = entries.firstIndex(where: { $0.node == current }) else {
            return entries.first?.node
        }
        return entries[min(max(index + delta, 0), entries.count - 1)].node
    }

    static func right<Node>(_ entries: [TreeEntry<Node>], from current: Node) -> Action<Node> {
        guard let index = entries.firstIndex(where: { $0.node == current }) else { return .none }
        switch entries[index].isOpen {
        case false?:
            return .open(current)
        case true?:
            let next = index + 1
            if entries.indices.contains(next), entries[next].parent == current {
                return .moveTo(entries[next].node)
            }
            return .none
        case nil:
            return .none
        }
    }

    static func left<Node>(_ entries: [TreeEntry<Node>], from current: Node) -> Action<Node> {
        guard let entry = entries.first(where: { $0.node == current }) else { return .none }
        if entry.isOpen == true { return .close(current) }
        if let parent = entry.parent { return .moveTo(parent) }
        return .none
    }

    /// The next row whose title starts with `prefix`, searching from the
    /// current row and wrapping. A fresh first letter starts *after* the
    /// current row, so pressing the same letter again moves on; a longer
    /// prefix keeps the current row if it still matches, so typing a whole
    /// name does not skip past it.
    static func match<Node>(_ entries: [TreeEntry<Node>], prefix: String, from current: Node?) -> Node? {
        guard !prefix.isEmpty, !entries.isEmpty else { return nil }
        let needle = prefix.lowercased()
        let start = entries.firstIndex(where: { $0.node == current }) ?? 0
        var order = Array(entries[start...] + entries[..<start])
        if needle.count == 1, current != nil { order = Array(order.dropFirst()) + order.prefix(1) }
        return order.first { $0.title.lowercased().hasPrefix(needle) }?.node
    }
}
