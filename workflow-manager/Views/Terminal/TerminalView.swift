//
//  TerminalView.swift
//  workflow-manager
//
//  The commands a project needs running, and their live output.
//
//  A sidebar of sessions rather than tabs: a project with six services has six
//  of these, and tabs stop being readable at about four. Each row carries its
//  own state dot and run control, so "is anything down?" is answerable without
//  selecting anything.
//
//  Sessions are owned by an app-level store, not by this view or the detail
//  view. Switching tabs or projects and back must not kill a dev server.
//

import SwiftUI
import SwiftData

struct TerminalView: View {
    @Bindable var project: Project
    var sessions: TerminalSessionsModel

    @Environment(\.modelContext) private var context

    @State private var selectedID: UUID?
    @State private var sheetTarget: TerminalCommandSheet.Target?

    private var selected: TerminalSession? {
        sessions.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        // Every child has to declare that it fills, and so does the split view
        // itself. `ContentUnavailableView` sizes to its content, so without
        // this the whole pane collapses to a small box and the parent centres
        // it — which is only invisible while a terminal happens to be running.
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 340, maxHeight: .infinity)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
        .task(id: project.uuid) {
            sessions.sync(with: project)
            if selectedID == nil { selectedID = sessions.sessions.first?.id }
        }
        // A command added, edited or deleted has to reach the session list.
        .onChange(of: commandsRevision) { _, _ in
            sessions.sync(with: project)
            if selected == nil { selectedID = sessions.sessions.first?.id }
        }
        // A card just launched a Claude session — bring it to the front.
        .onChange(of: sessions.lastStartedID) { _, id in
            if let id { selectedID = id }
        }
        .sheet(item: $sheetTarget) { target in
            TerminalCommandSheet(target: target, project: project)
        }
    }

    /// Changes to the saved commands, as one comparable value.
    private var commandsRevision: Int {
        var hasher = Hasher()
        for command in project.orderedTerminalCommands {
            hasher.combine(command.uuid)
            hasher.combine(command.name)
            hasher.combine(command.command)
            hasher.combine(command.directory)
            hasher.combine(command.isIncludedInRunAll)
        }
        return hasher.finalize()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if sessions.sessions.isEmpty {
                emptySidebar
            } else {
                List(selection: $selectedID) {
                    let saved = sessions.sessions.filter { $0.commandUUID != nil }
                    let adHoc = sessions.sessions.filter { $0.commandUUID == nil }

                    if !saved.isEmpty {
                        Section("Saved") {
                            ForEach(saved) { session in
                                row(for: session).tag(session.id)
                            }
                        }
                    }
                    if !adHoc.isEmpty {
                        Section("Terminals") {
                            ForEach(adHoc) { session in
                                row(for: session).tag(session.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Button {
                sessions.runAll(for: project)
            } label: {
                Label("Run All", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(runnableCount == 0 || sessions.isStartingAll)
            .help(runnableCount == 0
                  ? "Nothing to start"
                  : "Start \(runnableCount) command\(runnableCount == 1 ? "" : "s"), one after another")

            if sessions.hasRunning {
                Button {
                    sessions.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop everything")
            }

            Spacer()

            Menu {
                Button("New Command…") { sheetTarget = .new }
                Button("New Terminal") { newTerminal() }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var runnableCount: Int {
        let included = Set(
            project.orderedTerminalCommands.filter(\.isIncludedInRunAll).map(\.uuid)
        )
        return sessions.sessions.count { session in
            guard let uuid = session.commandUUID else { return false }
            return included.contains(uuid) && !session.isRunning
        }
    }

    private var emptySidebar: some View {
        VStack(spacing: 10) {
            Text("No commands yet")
                .font(.system(size: 12, weight: .medium))
            Text("Save the commands this project needs — a dev server, a watcher, a worker — and start them together.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Command…") { sheetTarget = .new }
                .controlSize(.small)
            Button("New Terminal") { newTerminal() }
                .controlSize(.small)
                .buttonStyle(.link)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(for session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            statusDot(for: session)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.statusSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                if session.isRunning {
                    session.stop()
                } else if session.command.isEmpty {
                    session.startShell()
                } else {
                    session.runSavedCommand()
                }
            } label: {
                Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(session.isRunning ? "Close this shell" : "Start")
        }
        .padding(.vertical, 2)
        .contextMenu { rowMenu(for: session) }
    }

    @ViewBuilder
    private func rowMenu(for session: TerminalSession) -> some View {
        if session.isRunning {
            Button("Interrupt (Ctrl-C)") { session.interrupt() }
            if !session.command.isEmpty {
                Button("Re-run Command") { session.runSavedCommand() }
            }
            Button("Close Shell", role: .destructive) { session.stop() }
        } else if session.command.isEmpty {
            Button("Start Shell") { session.startShell() }
        } else {
            Button("Run") { session.runSavedCommand() }
        }

        if let uuid = session.commandUUID,
           let command = project.terminalCommands.first(where: { $0.uuid == uuid }) {
            Divider()
            Button("Edit…") { sheetTarget = .edit(command) }
            Button("Delete Command", role: .destructive) {
                session.stop()
                context.delete(command)
            }
        } else {
            Divider()
            Button("Close Terminal", role: .destructive) {
                if selectedID == session.id {
                    selectedID = sessions.sessions.first { $0.id != session.id }?.id
                }
                sessions.remove(session)
            }
        }

        Divider()
        Button("Clear") { session.clearScreen() }
        Button("Copy Output") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.plainTextOutput, forType: .string)
        }
    }

    private func statusDot(for session: TerminalSession) -> some View {
        Circle()
            .fill(dotColor(for: session))
            .frame(width: 7, height: 7)
    }

    private func dotColor(for session: TerminalSession) -> Color {
        switch session.state {
        case .running:          .green
        case .exited(let code): code == 0 ? .secondary : .red
        case .failed:           .red
        case .idle:             Color.secondary.opacity(0.35)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            VStack(spacing: 0) {
                detailHeader(for: selected)
                Divider()
                if selected.isRunning {
                    TerminalScreenView(session: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    notStarted(selected)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Session Selected", systemImage: "terminal")
            } description: {
                Text("Pick a command on the left, or add one.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(for session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(displayPath(for: session))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if !session.command.isEmpty {
                Text(session.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            }

            if session.isRunning {
                Button { session.interrupt() } label: { Image(systemName: "xmark.octagon") }
                    .buttonStyle(.borderless)
                    .help("Interrupt (Ctrl-C)")
                if !session.command.isEmpty {
                    Button { session.runSavedCommand() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-run the command")
                }
                Button { session.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
                    .help("Close this shell")
            } else {
                Button {
                    session.command.isEmpty ? session.startShell() : session.runSavedCommand()
                } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Start")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func notStarted(_ session: TerminalSession) -> some View {
        ContentUnavailableView {
            Label(
                session.command.isEmpty ? "Shell Not Started" : "Not Running",
                systemImage: "terminal"
            )
        } description: {
            if case .exited(let code) = session.state, code != 0 {
                Text("The shell closed with code \(code).")
            } else if case .failed(let message) = session.state {
                Text(message)
            } else if session.command.isEmpty {
                Text("Start a shell in \(displayPath(for: session))")
            } else {
                Text(session.command)
                    .font(.system(size: 11, design: .monospaced))
            }
        } actions: {
            Button(session.command.isEmpty ? "Start Shell" : "Run") {
                session.command.isEmpty ? session.startShell() : session.runSavedCommand()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Repository-relative where possible — an absolute path is mostly noise
    /// once you know which project you are in.
    private func displayPath(for session: TerminalSession) -> String {
        let path = session.directory.path(percentEncoded: false)
        guard let root = project.repoDirectory?.path(percentEncoded: false) else { return path }
        if path == root { return "\(session.directory.lastPathComponent)/" }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1)) + "/"
        }
        return path
    }


    // MARK: - Actions

    private func newTerminal() {
        guard let root = project.repoDirectory else { return }
        let session = sessions.addAdHocSession(in: root)
        session.startShell()
        selectedID = session.id
    }
}
