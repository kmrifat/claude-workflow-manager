//
//  ProjectTimelineView.swift
//  workflow-manager
//
//  Gantt-ish layout of work items against the project's planned window.
//  Pure SwiftUI: a date axis plus offset capsules, no dependencies.
//

import SwiftUI
import SwiftData

struct ProjectTimelineView: View {
    @Environment(\.modelContext) private var context

    @Bindable var project: Project
    @Binding var inspectedItemID: UUID?
    let filter: BoardFilter

    private static let rowHeight: CGFloat = 30
    private static let labelWidth: CGFloat = 200

    /// The window the axis spans: the project's own window, widened to cover
    /// any item that starts before or ends after it, and today.
    private var window: (start: Date, end: Date) {
        var start = project.startDate
        var end = project.targetEndDate ?? Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start

        for item in scheduledItems {
            if let itemStart = item.effectiveStart, itemStart < start { start = itemStart }
            if let itemEnd = item.effectiveEnd, itemEnd > end { end = itemEnd }
        }
        if Date.now < start { start = Date.now }
        if Date.now > end { end = Date.now }
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start }
        return (start, end)
    }

    private var visibleItems: [WorkItem] {
        project.orderedColumns
            .flatMap(\.orderedItems)
            .filter { !filter.isActive || filter.matches($0) }
    }

    private var scheduledItems: [WorkItem] {
        visibleItems.filter { $0.startDate != nil || $0.dueDate != nil }
    }

    private var unscheduledItems: [WorkItem] {
        visibleItems.filter { $0.startDate == nil && $0.dueDate == nil }
    }

    var body: some View {
        Group {
            if visibleItems.isEmpty {
                ContentUnavailableView(
                    "Nothing to Show",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Add work items with start or due dates to see them on the timeline.")
                )
            } else {
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        axisHeader
                        Divider()
                        ForEach(scheduledItems, id: \.uuid) { item in
                            row(for: item)
                        }
                        if !unscheduledItems.isEmpty {
                            unscheduledTray
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(.background.secondary)
    }

    // MARK: - Axis

    private var axisHeader: some View {
        HStack(spacing: 0) {
            Text("Work item")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(tickDates, id: \.self) { date in
                        let x = fraction(for: date) * geometry.size.width
                        VStack(spacing: 2) {
                            Text(DateHelpers.chipLabel(for: date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Rectangle().fill(.quaternary).frame(width: 1, height: 6)
                        }
                        .offset(x: x - 18)
                    }
                }
            }
            .frame(height: 24)
        }
        .padding(.bottom, 4)
    }

    /// Six evenly spaced ticks across the window.
    private var tickDates: [Date] {
        let (start, end) = window
        let span = end.timeIntervalSince(start)
        return (0...5).map { start.addingTimeInterval(span * Double($0) / 5) }
    }

    private func fraction(for date: Date) -> Double {
        let (start, end) = window
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / span, 0), 1)
    }

    // MARK: - Rows

    private func row(for item: WorkItem) -> some View {
        HStack(spacing: 0) {
            Button {
                inspectedItemID = (inspectedItemID == item.uuid) ? nil : item.uuid
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.priority.color)
                        .frame(width: 6, height: 6)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Today marker
                    Rectangle()
                        .fill(.red.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: fraction(for: .now) * geometry.size.width)

                    let startFraction = fraction(for: item.effectiveStart ?? window.start)
                    let endFraction = fraction(for: item.effectiveEnd ?? window.end)
                    let width = max(6, (endFraction - startFraction) * geometry.size.width)

                    Capsule()
                        .fill(barTint(for: item).opacity(item.isDone ? 0.35 : 0.85))
                        .frame(width: width, height: 14)
                        .offset(x: startFraction * geometry.size.width)
                        .overlay(alignment: .leading) {
                            if inspectedItemID == item.uuid {
                                Capsule()
                                    .strokeBorder(.primary, lineWidth: 1.5)
                                    .frame(width: width, height: 14)
                                    .offset(x: startFraction * geometry.size.width)
                            }
                        }
                        .help(tooltip(for: item))
                }
            }
            .frame(height: Self.rowHeight)
        }
        .frame(height: Self.rowHeight)
    }

    private func barTint(for item: WorkItem) -> Color {
        if item.isOverdue { return .red }
        if item.isDone { return .green }
        return project.accent.color
    }

    private func tooltip(for item: WorkItem) -> String {
        let start = item.effectiveStart.map(DateHelpers.mediumLabel) ?? "—"
        let end = item.effectiveEnd.map(DateHelpers.mediumLabel) ?? "—"
        return "\(item.title)\n\(start) → \(end)"
    }

    private var unscheduledTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 8)
            Text("Unscheduled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(unscheduledItems.prefix(12), id: \.uuid) { item in
                    Button {
                        inspectedItemID = item.uuid
                    } label: {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                if unscheduledItems.count > 12 {
                    Text("+\(unscheduledItems.count - 12) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension WorkItem {
    /// Falls back to the due date so single-dated items still draw a bar.
    var effectiveStart: Date? { startDate ?? dueDate }
    var effectiveEnd: Date? { dueDate ?? startDate }
}

#if DEBUG
#Preview {
    @Previewable @State var inspected: UUID?
    if let project = SampleData.firstProject {
        ProjectTimelineView(project: project, inspectedItemID: $inspected, filter: BoardFilter())
            .modelContainer(SampleData.container)
            .frame(width: 1000, height: 600)
    }
}
#endif
