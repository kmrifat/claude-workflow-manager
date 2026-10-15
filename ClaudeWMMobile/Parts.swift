//
//  Parts.swift
//  ClaudeWMMobile
//
//  The pieces the phone's screens share, drawn to `design/ClaudeWM.fig` ›
//  Mobile · iPhone: the colours a column, a priority and Claude wear, the
//  pill-shaped chips, and the round initials badge. Colours follow the Mac's
//  board so a card looks like the same card on both.
//

import SwiftUI
import ClaudeWMWire

enum Palette {
    /// Claude, everywhere: the callout, the "working" dot, the note button.
    static let claude = Color(red: 0.75, green: 0.35, blue: 0.95)
    static let review = Color(red: 0.75, green: 0.35, blue: 0.95)

    static func column(_ role: WireColumnRole?) -> Color {
        switch role {
        case .todo:       .blue
        case .inProgress: .orange
        case .review:     review
        case .done:       .green
        case nil:         .secondary
        }
    }

    static func priority(_ priority: WirePriority) -> Color {
        switch priority {
        case .urgent: .red
        case .high:   .orange
        case .normal: .secondary
        case .low:    .secondary
        }
    }

    /// A project's accent, by the Mac's name for it.
    static func accent(_ name: String?) -> Color {
        switch name {
        case "purple": .purple
        case "pink":   .pink
        case "red":    .red
        case "orange": .orange
        case "yellow": .yellow
        case "green":  .green
        case "teal":   .teal
        case "gray":   .gray
        default:       .blue
        }
    }
}

extension WirePriority {
    var title: String { rawValue.capitalized }
}

/// A rounded pill: a field's value, a column, a filter.
struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    var filled = false
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
        .background(
            Capsule().fill(filled ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(Color(.tertiarySystemFill)))
        )
        .overlay(Capsule().strokeBorder(filled ? tint.opacity(0.35) : .clear, lineWidth: 1))
    }
}

/// A chip that has nothing in it yet: "+ Due", "+ Owner".
struct EmptyChip: View {
    var text: String

    var body: some View {
        Text("+ \(text)")
            .font(.footnote)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(.secondary)
            .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 1))
    }
}

/// Someone's initials in a circle, the owner on a card.
struct Initials: View {
    var name: String
    var size: CGFloat = 20

    var body: some View {
        Text(Self.initials(of: name))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.accent(Self.colour(of: name))))
    }

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters.isEmpty ? Array(name.prefix(2)) : letters).uppercased()
    }

    /// Stable per name, so the same person is the same colour on every card.
    private static func colour(of name: String) -> String {
        let names = ["blue", "teal", "green", "orange", "pink", "purple"]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return names[sum % names.count]
    }
}

/// "Claude is working · Editing TokenRefresher.swift": the purple callout a
/// card shows while it is with Claude.
struct ClaudeCallout: View {
    var state: WireAgentState
    var detail: String?
    var since: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Palette.claude).frame(width: 6, height: 6)
                Text(Self.title(of: state))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.claude)
                Spacer(minLength: 0)
                if let since {
                    Text(since, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.claude.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.claude.opacity(0.3), lineWidth: 1))
    }

    static func title(of state: WireAgentState) -> String {
        switch state {
        case .queued:   "Waiting for Claude"
        case .working:  "Claude is working"
        case .inReview: "Ready for review"
        case .done:     "Claude finished"
        case .none:     "With Claude"
        }
    }
}

extension WireAgentState {
    /// The states worth a callout on a card. Review and done are shown by the
    /// column the card is in.
    var isActive: Bool { self == .queued || self == .working }
}

extension Date {
    /// "13 Oct", the way the Mac's board writes a due date.
    var shortDay: String { formatted(.dateTime.day().month(.abbreviated)) }
}
