//
//  ProjectMetricsPill.swift
//  workflow-manager
//
//  The project's live signals, compressed to fit a toolbar slot so the board
//  keeps the whole window below the title bar.
//

import SwiftUI
import SwiftData

struct ProjectMetricsPill: View {
    @Bindable var project: Project

    var body: some View {
        HStack(spacing: 7) {
            // Status lives here rather than in its own toolbar control: as a
            // toolbar `Label` it collapsed to a bare, unreadable glyph.
            Circle()
                .fill(project.status.color)
                .frame(width: 6, height: 6)
            Text(project.status.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("·").foregroundStyle(.tertiary)

            if project.totalCount > 0 {
                Text("\(Int((project.progress * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()

                ZStack(alignment: .leading) {
                    ProgressCapsule(progress: project.progress, tint: project.accent.color, height: 6)

                    // Where today sits in the planned window: if the tick is
                    // ahead of the fill, the project is behind schedule.
                    if let elapsed = project.timeElapsed {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.primary.opacity(0.6))
                                .frame(width: 2, height: 10)
                                .offset(x: elapsed * geometry.size.width - 1, y: -2)
                        }
                        .frame(height: 6)
                    }
                }
                .frame(width: 84, height: 6)

                Text("\(project.completedCount)/\(project.totalCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("No items yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if project.overdueCount > 0 {
                Label("\(project.overdueCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let days = project.daysRemaining {
                Text("·").foregroundStyle(.tertiary)
                Text(DateHelpers.remainingDescription(days: days))
                    .font(.caption)
                    .foregroundStyle(days < 0 ? .red : .secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .help(verdict)
    }

    private var verdict: String {
        guard project.totalCount > 0 else { return "No work items yet — click for the project brief" }
        if project.timeElapsed == nil { return "\(project.completedCount) of \(project.totalCount) done" }
        if project.isBehindSchedule {
            let behind = project.itemsBehind
            return behind > 0 ? "Behind by ~\(behind) item\(behind == 1 ? "" : "s")" : "Behind schedule"
        }
        return "On track"
    }
}
