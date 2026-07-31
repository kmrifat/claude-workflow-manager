//
//  ProjectRow.swift
//  workflow-manager
//

import SwiftUI

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: project.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(project.accent.color)
                .frame(width: 22, height: 22)
                .background(project.accent.color.opacity(0.15), in: .rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(project.name.isEmpty ? "Untitled Project" : project.name)
                        .lineLimit(1)
                    if project.overdueCount > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .help("\(project.overdueCount) overdue item(s)")
                    }
                }

                if project.totalCount > 0 {
                    ProgressCapsule(progress: project.progress, tint: project.accent.color)
                    Text("\(project.completedCount)/\(project.totalCount) done")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !project.summary.isEmpty {
                    Text(project.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Thin progress bar used in the sidebar and on cards.
struct ProgressCapsule: View {
    let progress: Double
    var tint: Color = .accentColor
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}
