//
//  ProjectRow.swift
//  workflow-manager
//

import SwiftUI

struct ProjectRow: View {
    let project: Project

    /// Optional so previews (which don't inject the store) don't trap — they
    /// simply show no run control.
    @Environment(TerminalStateStore.self) private var terminalStore: TerminalStateStore?

    /// The project's terminal sessions, if the store is present. Reading its
    /// running state here is what makes the sidebar reflect a live dev server
    /// without opening the Terminal tab.
    private var sessions: TerminalSessionsModel? {
        terminalStore?.model(for: project.uuid)
    }

    private var runningCount: Int { sessions?.runningCount ?? 0 }
    private var isRunning: Bool { runningCount > 0 }

    /// Whether "Run All" would start anything — a linked repo with at least one
    /// command opted into it.
    private var hasRunnableCommands: Bool {
        project.hasRepository
            && project.orderedTerminalCommands.contains(where: \.isIncludedInRunAll)
    }

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

                    if isRunning {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .help("\(runningCount) command\(runningCount == 1 ? "" : "s") running")
                    }

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

            Spacer(minLength: 0)

            runControl
        }
        .padding(.vertical, 3)
    }

    /// Start-all / stop-all, right on the row. Icon doubles as state: a red stop
    /// means something is running, a play means idle-with-commands, and a project
    /// with nothing to run shows no control at all.
    @ViewBuilder
    private var runControl: some View {
        if isRunning {
            Button {
                sessions?.stopAll()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Stop all commands")
        } else if hasRunnableCommands {
            Button(action: startAll) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Run all commands")
        }
    }

    /// Syncs the model to the saved commands first — the store may never have
    /// been touched for this project — then starts everything opted into Run All.
    private func startAll() {
        guard let sessions else { return }
        sessions.sync(with: project)
        sessions.runAll(for: project)
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
