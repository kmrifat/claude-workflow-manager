//
//  DateHelpers.swift
//  workflow-manager
//

import Foundation

/// `nonisolated` because rows and layout helpers format dates outside the
/// main actor, and the target defaults every type to `@MainActor`.
nonisolated enum DateHelpers {
    /// Whole calendar days between the *start of day* of each date, so
    /// "tomorrow at 09:00" reads as 1 day away regardless of the clock.
    static func wholeDays(from: Date, to: Date) -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// "24 days left", "Due today", "Overdue by 3 days".
    static func remainingDescription(days: Int) -> String {
        switch days {
        case 0:            "Due today"
        case 1:            "1 day left"
        case let d where d > 1:  "\(d) days left"
        case -1:           "Overdue by 1 day"
        default:           "Overdue by \(abs(days)) days"
        }
    }

    /// Short label for a due-date chip: "Mar 14".
    static func chipLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Medium label used in headers: "14 Mar 2026".
    static func mediumLabel(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Inclusive day count of a planned window, minimum 1.
    static func durationInDays(from start: Date, to end: Date) -> Int {
        max(1, (wholeDays(from: start, to: end) ?? 0))
    }
}
