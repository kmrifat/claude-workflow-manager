//
//  BranchSummaryView.swift
//  workflow-manager
//
//  What is on an issue's branch. Two densities: a one-line badge for the card,
//  and a full section for the detail sheet.
//

import SwiftUI

/// Compact form for a board card.
struct BranchBadge: View {
    let summary: GitReader.BranchSummary
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))

            Text(summary.branch)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if summary.isEmpty {
                // A worktree exists before the first commit lands; saying
                // "no commits" is more useful than showing 0.
                Text("no commits")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(summary.commitCount)c")
                    .font(.system(size: 9, weight: .medium))
                Text("+\(summary.insertions)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                Text("−\(summary.deletions)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(accent.opacity(0.12), in: .capsule)
        .foregroundStyle(accent)
        .help("\(summary.branch) vs \(summary.baseBranch)")
    }
}

/// Full form for the detail sheet.
struct BranchSummarySection: View {
    let summary: GitReader.BranchSummary

    private static let maxCommitsShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(summary.branch)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                Text("vs \(summary.baseBranch)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if summary.isEmpty {
                Text("The branch exists but has no commits yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    stat("\(summary.commitCount)", summary.commitCount == 1 ? "commit" : "commits")
                    stat("\(summary.filesChanged)", summary.filesChanged == 1 ? "file" : "files")
                    stat("+\(summary.insertions)", "added", tint: .green)
                    stat("−\(summary.deletions)", "removed", tint: .red)
                    if let last = summary.lastCommitAt {
                        stat(DateHelpers.chipLabel(for: last), "last commit")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.commits.prefix(Self.maxCommitsShown)) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(commit.sha)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(commit.subject)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    if summary.commitCount > Self.maxCommitsShown {
                        Text("+ \(summary.commitCount - Self.maxCommitsShown) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 8))
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }
}
