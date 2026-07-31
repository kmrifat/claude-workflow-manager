import AppKit
import SwiftUI
import WorkflowCore

/// The popover: what is running, what is ready, and how to get to the rest.
///
/// Same information as the web dashboard, at a glance. It is not trying to be
/// the dashboard — it is trying to answer "do I need to look?".
struct HostAppMenu: View {
    @Bindable var model: HostAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            switch model.phase {
            case .starting:
                message("Starting…", systemImage: "hourglass")
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Host didn’t start", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
            case .running:
                content
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.tint)
            Text("WorkflowHost")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let at = model.lastRefresh {
                Text(at, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if let state = model.state, !state.repos.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.repos) { repo in
                        repoSection(repo)
                    }
                    if !state.recentEvents.isEmpty {
                        Divider()
                        Text("Recent")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(state.recentEvents.prefix(6)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(event.kind.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(tint(for: event.kind))
                                Text(event.detail ?? "")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 320)
        } else {
            message("Nothing configured yet.", systemImage: "tray")
        }
    }

    private func repoSection(_ repo: RepoState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(repo.id)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(repo.activeRuns.count)/\(repo.maxConcurrent)")
                    .font(.system(size: 10))
                    .foregroundStyle(repo.hasCapacity ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }

            if repo.activeRuns.isEmpty {
                Text("\(repo.readyIssues.count) ready · nothing running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(repo.activeRuns) { view in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(view.run.status == .running ? Color.green : Color.purple)
                            .frame(width: 5, height: 5)
                        Text("#\(view.run.issueNumber) \(view.issueTitle ?? "")")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let git = view.git, !git.isEmpty {
                            Text("\(git.commitCount)c")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // A sleeping Mac otherwise reads as a quiet one.
            if let polled = repo.lastPolledAt {
                Text("polled \(polled, style: .relative) ago")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text("never polled")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open Dashboard") { model.openDashboard() }
                .font(.system(size: 11))
            Button("Refresh") { Task { await model.refresh() } }
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private func tint(for kind: EventKind) -> Color {
        switch kind {
        case .prOpened: .purple
        case .failed: .red
        case .dispatched: .blue
        case .blocked, .stopped: .orange
        case .commit: .secondary
        }
    }
}
