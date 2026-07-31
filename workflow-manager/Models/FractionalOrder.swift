//
//  FractionalOrder.swift
//  workflow-manager
//
//  SwiftData to-many relationships are *unordered* — array position is not
//  persisted. Everything that needs a user-visible order (cards in a column,
//  columns on a board, projects in the sidebar) carries an explicit
//  `sortOrder: Double`, and new positions are found by taking the midpoint
//  between two neighbours. That keeps a drag to a single dirtied object.
//

import Foundation

enum FractionalOrder {
    /// Spacing used when appending or when normalizing a whole list.
    static let step: Double = 1024

    /// Once neighbouring orders get this close, the `Double` mantissa is
    /// running out of room and the list should be renumbered.
    static let minGap: Double = 0.0001

    /// The order value for a slot between two neighbours. Either side may be
    /// `nil`, meaning "insert at the very start / very end".
    static func between(_ prev: Double?, _ next: Double?) -> Double {
        switch (prev, next) {
        case (nil, nil):                return step
        case (nil, let next?):          return next - step
        case (let prev?, nil):          return prev + step
        case (let prev?, let next?):    return (prev + next) / 2
        }
    }

    /// The order value that appends after every element of `existing`.
    static func afterLast(of existing: [Double]) -> Double {
        (existing.max() ?? 0) + step
    }

    /// True when any adjacent pair in an ascending list has collapsed.
    static func needsNormalization(_ ascending: [Double]) -> Bool {
        zip(ascending, ascending.dropFirst()).contains { $1 - $0 < minGap }
    }

    /// Evenly spaced orders for a list of `count` elements: 1024, 2048, ...
    static func normalizedOrders(count: Int) -> [Double] {
        (0..<count).map { Double($0 + 1) * step }
    }
}
