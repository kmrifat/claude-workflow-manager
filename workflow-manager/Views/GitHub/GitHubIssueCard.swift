//
//  GitHubIssueCard.swift
//  workflow-manager
//
//  Matches WorkItemCardView's chrome so the two boards read as one app, but
//  carries no editing affordances — these cards mirror GitHub and nothing here
//  can change it.
//

import SwiftUI

struct GitHubIssueCard: View {
    let issue: GitHubIssue
    var accent: Color = .accentColor
    /// Local branch progress, when a branch for this issue exists.
    var branchSummary: GitReader.BranchSummary?
    /// Whether a card on this project's board already tracks this issue.
    /// Derived from a live scan of the board, never stored issue-side.
    var trackedLocally: Bool = false
    /// Supplied by the board; absent in contexts with no board to act on.
    var onAddToBoard: (() -> Void)?
    var onRevealOnBoard: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("#\(issue.number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if trackedLocally {
                    Image(systemName: BoardViewMode.board.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .help("Tracked on this project's board")
                }

                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)

                Spacer(minLength: 0)
            }

            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3)) { label in
                        Text(label.name)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(label.swiftUIColor.opacity(0.18), in: .capsule)
                            .foregroundStyle(label.swiftUIColor)
                    }
                    if issue.labels.count > 3 {
                        Text("+\(issue.labels.count - 3)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let branchSummary {
                BranchBadge(summary: branchSummary, accent: accent)
            }

            HStack(spacing: 8) {
                Label(
                    DateHelpers.chipLabel(for: issue.updatedAt),
                    systemImage: "clock"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

                Spacer(minLength: 0)

                ForEach(issue.assignees.prefix(3)) { assignee in
                    Text(assignee.login.prefix(2).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.quaternary, in: .circle)
                        .help(assignee.login)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .contentShape(.rect)
        .help("Click for details")
        .contextMenu {
            if trackedLocally {
                if let onRevealOnBoard {
                    Button("Reveal on Board", action: onRevealOnBoard)
                }
            } else if let onAddToBoard {
                Button("Add to Board", action: onAddToBoard)
            }
            Link("Open on GitHub", destination: issue.url)
            Button("Copy Issue Number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("#\(issue.number)", forType: .string)
            }
        }
    }
}

extension GitHubIssue.Label {
    /// GitHub sends six hex digits with no `#`.
    var swiftUIColor: Color {
        guard color.count == 6, let value = Int(color, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
