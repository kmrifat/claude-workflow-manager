//
//  ProjectOverviewSheet.swift
//  workflow-manager
//
//  The full project brief, moved off the board screen so the header can stay
//  one row tall. Opened by clicking the header.
//

import SwiftUI
import SwiftData

struct ProjectOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var project: Project
    /// Called before dismissing; the presenter opens the editor afterwards.
    var onRequestEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scheduleSection
                    if !project.goal.isEmpty { section("Goal", icon: "target", body: project.goal) }
                    if !project.plan.isEmpty { section("Plan", icon: "list.bullet.rectangle", body: project.plan) }
                    breakdownSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Button("Edit Project…") {
                    onRequestEdit()
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 560)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: project.symbolName)
                .font(.title)
                .foregroundStyle(project.accent.color)
                .frame(width: 40, height: 40)
                .background(project.accent.color.opacity(0.15), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    .font(.title2.weight(.semibold))
                if !project.summary.isEmpty {
                    Text(project.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Label(project.status.title, systemImage: project.status.symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(project.status.color.opacity(0.15), in: .capsule)
                .foregroundStyle(project.status.color)
        }
        .padding(20)
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(Int((project.progress * 100).rounded()))% complete")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()

                if project.timeElapsed != nil {
                    Text(scheduleVerdict)
                        .font(.caption)
                        .foregroundStyle(project.isBehindSchedule ? .orange : .green)
                }

                Spacer(minLength: 0)

                if let days = project.daysRemaining {
                    Label(
                        DateHelpers.remainingDescription(days: days),
                        systemImage: days < 0 ? "exclamationmark.triangle.fill" : "calendar"
                    )
                    .font(.caption)
                    .foregroundStyle(days < 0 ? .red : .secondary)
                }
            }

            ZStack(alignment: .leading) {
                ProgressCapsule(progress: project.progress, tint: project.accent.color, height: 10)

                if let elapsed = project.timeElapsed {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.primary.opacity(0.55))
                            .frame(width: 2, height: 14)
                            .offset(x: elapsed * geometry.size.width - 1, y: -2)
                            .help("Today, against the planned window")
                    }
                    .frame(height: 10)
                }
            }
            .frame(height: 10)

            HStack(spacing: 4) {
                Text(DateHelpers.mediumLabel(for: project.startDate))
                if let end = project.targetEndDate {
                    Text("→")
                    Text(DateHelpers.mediumLabel(for: end))
                } else {
                    Text("· no target end date")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            HStack(spacing: 14) {
                stat("\(project.completedCount)", "done", .green)
                stat("\(project.openCount)", "open", .secondary)
                if project.overdueCount > 0 {
                    stat("\(project.overdueCount)", "overdue", .red)
                }
            }
            .padding(.top, 2)
        }
    }

    private func section(_ title: String, icon: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Per-column counts, so the sheet says something the board doesn't.
    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Columns", systemImage: "rectangle.split.3x1")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(project.orderedColumns, id: \.uuid) { column in
                HStack(spacing: 8) {
                    Text(column.name)
                        .font(.callout)
                    if column.isCompletionColumn {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 8)
                    Text(column.wipLimit.map { "\(column.items.count)/\($0)" } ?? "\(column.items.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(column.isOverWIP ? .red : .secondary)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scheduleVerdict: String {
        guard project.totalCount > 0 else { return "No items yet" }
        if project.isBehindSchedule {
            let behind = project.itemsBehind
            return behind > 0 ? "Behind by ~\(behind) item\(behind == 1 ? "" : "s")" : "Behind schedule"
        }
        return "On track"
    }
}

#if DEBUG
#Preview {
    if let project = SampleData.firstProject {
        ProjectOverviewSheet(project: project) {}
            .modelContainer(SampleData.container)
    }
}
#endif
