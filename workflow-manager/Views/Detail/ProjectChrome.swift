//
//  ProjectChrome.swift
//  workflow-manager
//
//  The frame around a project's content, per design/ClaudeWM.fig › W02: the
//  scope bar above the cards and the status bar along the bottom. The toolbar
//  is all system controls — see `ProjectDetailView.toolbarContent`.
//

import SwiftUI

/// Above the board, list and timeline: a quick scope, the filters, and how the
/// project is doing.
struct ScopeBar: View {
    @Bindable var project: Project
    @Binding var filter: BoardFilter

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(BoardScope.allCases) { scope in
                    Button {
                        filter.scope = scope
                    } label: {
                        Text(scope.title)
                            .font(.system(size: 12, weight: filter.scope == scope ? .semibold : .regular))
                            .foregroundStyle(filter.scope == scope ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(
                                filter.scope == scope ? Color.primary.opacity(0.1) : .clear,
                                in: .rect(cornerRadius: 5)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 16)

            popup("Priority", value: filter.minimumPriority.map { "\($0.title)+" }) {
                Button(filter.minimumPriority == nil ? "✓ Any" : "Any") { filter.minimumPriority = nil }
                Divider()
                ForEach(Priority.allCases.reversed()) { priority in
                    Button(filter.minimumPriority == priority ? "✓ \(priority.title) and above" : "\(priority.title) and above") {
                        filter.minimumPriority = priority
                    }
                }
            }

            if !tagOptions.isEmpty {
                popup("Tag", value: filter.tag) {
                    Button(filter.tag == nil ? "✓ Any" : "Any") { filter.tag = nil }
                    Divider()
                    ForEach(tagOptions, id: \.self) { tag in
                        Button(filter.tag == tag ? "✓ \(tag)" : tag) { filter.tag = tag }
                    }
                }
            }

            if !ownerOptions.isEmpty {
                popup("Owner", value: filter.owner) {
                    Button(filter.owner == nil ? "✓ Anyone" : "Anyone") { filter.owner = nil }
                    Divider()
                    ForEach(ownerOptions, id: \.self) { owner in
                        Button(filter.owner == owner ? "✓ \(owner)" : owner) { filter.owner = owner }
                    }
                }
            }

            if filter.isActive {
                Button("Clear") { filter.clear() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }

            Spacer(minLength: 8)

            if project.totalCount > 0 {
                HStack(spacing: 8) {
                    Text("\(project.completedCount) of \(project.totalCount) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ProgressCapsule(progress: project.progress, tint: Theme.running)
                        .frame(width: 110)
                    Text("\(Int((project.progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }

            if let end = project.targetEndDate, let days = project.daysRemaining {
                Divider().frame(height: 16)
                Label {
                    Text(days < 0
                         ? "\(-days) days late"
                         : "Due \(end.formatted(.dateTime.month(.abbreviated).day())) · \(days) days")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.system(size: 11))
                .foregroundStyle(days < 0 ? Theme.danger : (project.isBehindSchedule ? Theme.warning : .secondary))
                .help(project.isBehindSchedule ? "About \(project.itemsBehind) cards behind schedule" : "Target end date")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// A macOS pop-up button in miniature: label, current value, up-down arrows.
    private func popup<Items: View>(
        _ title: String,
        value: String?,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Text("\(title): \(value ?? "Any")")
                    .font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.primary.opacity(value == nil ? 0.06 : 0.12), in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var ownerOptions: [String] {
        Array(Set(project.allItems.map(\.owner).filter { !$0.isEmpty })).sorted()
    }

    private var tagOptions: [String] {
        Array(Set(project.allItems.flatMap(\.tags))).sorted()
    }
}

/// The 24 pt strip along the bottom: what is on the board, and whether Claude
/// is connected to it.
struct ProjectStatusBar: View {
    @Bindable var project: Project
    var runningCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Text(summary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if runningCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Theme.running).frame(width: 6, height: 6)
                    Text("\(runningCount) command\(runningCount == 1 ? "" : "s") running")
                }
            }
            syncStatus
            if let slug = project.repoSlug {
                Label(slug, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            } else if let path = project.repoPath {
                Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let agents = project.allItems.count { $0.agentState == .working }
        var parts = [
            "\(project.totalCount) card\(project.totalCount == 1 ? "" : "s")",
            "\(project.openCount) open",
            "\(project.inProgressCount) in progress",
        ]
        if agents > 0 { parts.append("\(agents) with Claude") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var syncStatus: some View {
        if project.isSyncing {
            HStack(spacing: 5) {
                Circle().fill(Theme.agent).frame(width: 6, height: 6)
                Text("Claude sync on")
            }
        } else if project.workflowSyncEnabled {
            HStack(spacing: 5) {
                Circle().fill(Theme.warning).frame(width: 6, height: 6)
                Text("Claude sync needs a column status")
            }
        } else if project.hasRepository {
            Text("Claude sync off")
        }
    }
}
