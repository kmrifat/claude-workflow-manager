//
//  SettingsView.swift
//  workflow-manager
//
//  Settings, in the main window (DevVault's owner decision, carried over).
//  Laid out to design/ClaudeWM.fig › S01: one centred 760 pt column of group
//  boxes, not a grouped `Form` — the design's hero card, command well and
//  two-column permission grid have no `Form` equivalent, and a `Form` that only
//  approximates them looked like a different app.
//
//  Panes switch from the toolbar with a system segmented control, the same
//  control the project header uses: anything carrying its own background in a
//  Liquid Glass toolbar ends up as a pill inside a pill.
//

import SwiftUI
import SwiftData
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case claude
    case remote
    case devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:  "Claude & MCP"
        case .remote:  "Remote"
        case .devices: "Devices"
        }
    }
}

struct SettingsView: View {
    @Bindable var server: MCPServer
    let boardServer: BoardServer
    @Bindable var tailnet: TailnetAccess

    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @AppStorage("settings.pane") private var pane: SettingsPane = .claude
    @AppStorage("boardNotificationsEnabled") private var notifyOnMoves = true

    @State private var revealsToken = false
    @State private var confirmsRotation = false
    @State private var copied = false
    @State private var showsAllTools = false
    @State private var copiedRemote = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch pane {
                case .claude: claudePane
                case .remote: remotePane
                case .devices: devicesPane
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("Settings")
        .navigationSubtitle(pane.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Settings", selection: $pane) {
                    ForEach(SettingsPane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear { server.loadToken() }
        .confirmationDialog("Rotate the MCP token?", isPresented: $confirmsRotation) {
            Button("Rotate Token", role: .destructive) {
                server.rotateToken()
                revealsToken = false
            }
        } message: {
            Text("Every Claude Code set up with the current token stops connecting until you run the new command.")
        }
    }

    // MARK: - Claude & MCP

    @ViewBuilder
    private var claudePane: some View {
        hero(
            symbol: "powerplug.portrait.fill",
            tint: .accentColor,
            title: "MCP server",
            isOn: $server.isEnabled
        ) {
            serverStatus
        }

        Text("Claude reads and changes your boards through MCP tools instead of editing .taskboard/tasks.json. Every change lands on the board at once, is checked against your rules, and shows in the card’s activity.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        connectGroup
        clientsGroup
        permissionsGroup
        migrationBanner
        if !server.recentCalls.isEmpty { callsGroup }
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch server.state {
        case .running:
            StatusLine(color: Theme.running, text: runningSummary)
        case .starting:
            StatusLine(color: .secondary, text: "Starting…")
        case .failed(let message):
            StatusLine(color: Theme.danger, text: message, isError: true)
        case .stopped:
            StatusLine(color: .secondary, text: "Off · only this Mac can reach it when on")
        }
    }

    private var runningSummary: String {
        var parts = ["Running", server.url]
        if let since = server.runningSince {
            parts.append("up \(Self.uptime(since: since))")
        }
        let count = server.sessions.count
        parts.append("\(count) client\(count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private var connectGroup: some View {
        SettingsSection(title: "Connect Claude Code") {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run once in any terminal. Claude Code then sees every project on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    commandWell(server.connectCommand, copied: $copied)
                }
                .padding(14)

                GroupDivider()

                GroupRow(
                    title: "Token",
                    subtitle: "Kept in your Keychain. Added for your user, never written into a repository."
                ) {
                    Button(revealsToken ? "Hide" : "Show") { revealsToken.toggle() }
                    Button("Rotate…") { confirmsRotation = true }
                }
            }
        }
    }

    /// A command in a well, token masked unless revealed, with Copy inside.
    private func commandWell(_ command: String, copied: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(revealsToken ? command : masked(command))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied.wrappedValue = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied.wrappedValue = false
                }
            } label: {
                Label(copied.wrappedValue ? "Copied" : "Copy",
                      systemImage: copied.wrappedValue ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(server.token.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.codeWell, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline) }
    }

    private func masked(_ command: String) -> String {
        guard !server.token.isEmpty else { return command }
        return command.replacingOccurrences(
            of: server.token,
            with: String(server.token.prefix(4)) + String(repeating: "•", count: 12)
        )
    }

    private var clientsGroup: some View {
        SettingsSection(title: "Connected clients", trailing: "Need the token to connect") {
            SettingsGroup {
                if server.sessions.isEmpty {
                    Text(server.state.isRunning
                         ? "No client has connected since the server started."
                         : "Turn the server on, then start Claude Code in a project.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(server.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { GroupDivider() }
                    clientRow(session)
                }
            }
        }
    }

    private func clientRow(_ session: MCPServer.Session) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(light: 0xD97757, dark: 0xD97757).gradient, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(.system(size: 13, weight: .medium))
                Text("\(session.calls) call\(session.calls == 1 ? "" : "s") · MCP \(session.protocolVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(Theme.running).frame(width: 6, height: 6)
                Text(session.lastSeen, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    /// Read-only: these are the tools that exist, not switches. A checkbox
    /// that cannot be unchecked would be a lie, so they are drawn as marks.
    private var permissionsGroup: some View {
        SettingsSection(title: "What agents may do") {
            Button(showsAllTools ? "Hide tools" : "See all \(MCPTools.definitions.count) tools") {
                withAnimation(.snappy) { showsAllTools.toggle() }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        } content: {
            SettingsGroup {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Permission("Read boards and cards", allowed: true)
                        Permission("Claim a card and move it", allowed: true)
                        Permission("Check off subtasks, add notes", allowed: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Permission("Set branch and PR link", allowed: true)
                        Permission("Rename or rewrite cards", allowed: false)
                        Permission("Create or delete cards", allowed: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)

                if showsAllTools {
                    ForEach(MCPTools.definitions, id: \.name) { tool in
                        GroupDivider()
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(tool.name)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 110, alignment: .leading)
                            Text(tool.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(tool.readOnly ? "Reads" : "Changes")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tool.readOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.agentText))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var migrationBanner: some View {
        let fileSynced = projects.filter(\.workflowSyncEnabled)
        if !fileSynced.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.link)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fileSynced.count) project\(fileSynced.count == 1 ? "" : "s") still sync\(fileSynced.count == 1 ? "s" : "") through .taskboard/tasks.json")
                        .font(.system(size: 13, weight: .medium))
                    Text("\(fileSynced.count == 1 ? "It keeps" : "They keep") working alongside MCP — the file reflects every change Claude makes here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Theme.link.opacity(0.08), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.link.opacity(0.25)) }
        }
    }

    private var callsGroup: some View {
        SettingsSection(title: "Recent calls") {
            SettingsGroup {
                ForEach(Array(server.recentCalls.prefix(8).enumerated()), id: \.element.id) { index, call in
                    if index > 0 { GroupDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: call.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(call.succeeded ? Theme.running : Theme.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.tool).font(.system(size: 12, design: .monospaced))
                            if let message = call.message {
                                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(call.client).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(call.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                }
            }
        }
    }

    // MARK: - Remote

    @ViewBuilder
    private var remotePane: some View {
        hero(
            symbol: "globe",
            tint: Color(light: 0x30B0C7, dark: 0x30B0C7),
            title: "Access from anywhere",
            isOn: $tailnet.isEnabled
        ) {
            remoteStatus
        }
        .task { await tailnet.refresh() }

        Text("Off the Wi-Fi, your phone and your other Macs reach this one over your tailnet, device to device. Nothing of ours sits in between, and each service still asks for its own key — being on the tailnet is not enough to get in.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SettingsSection(title: "Route") {
            HStack(alignment: .top, spacing: 10) {
                routeCard(
                    title: "Tailscale",
                    badges: tailscaleBadges,
                    text: "Your tailnet only, device to device. No server of ours, nothing in between.",
                    isSelected: true
                )
                routeCard(
                    title: "Cloudflare Tunnel",
                    badges: [("Not built yet", false)],
                    text: "A hostname you own through cloudflared. Planned, not available.",
                    isSelected: false
                )
                .opacity(0.55)
            }
        }

        if tailnet.status == .notInstalled {
            installBanner
        }

        SettingsSection(title: "Reachable over Tailscale") {
            SettingsGroup {
                GroupRow(title: "MCP server", subtitle: mcpReachSubtitle) {
                    Toggle("MCP server over Tailscale", isOn: $tailnet.exposesMCP)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                GroupDivider()
                GroupRow(title: "Phone Access", subtitle: phoneReachSubtitle) {
                    Toggle("Phone Access over Tailscale", isOn: $tailnet.exposesPhone)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                GroupDivider()
                GroupRow(
                    title: "Terminal and Files",
                    subtitle: "Follow the switches in Phone Access, wherever the phone is."
                ) {
                    Button("Phone Access…") {
                        NotificationCenter.default.post(name: .phoneAccessRequested, object: nil)
                    }
                }
            }
        }

        if let command = server.remoteConnectCommand {
            SettingsSection(title: "Connect from another Mac") {
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run on any Mac signed in to the same tailnet. It reaches this Mac’s boards over Tailscale.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        commandWell(command, copied: $copiedRemote)
                    }
                    .padding(14)
                }
            }
        }

        if let node = tailnet.phoneNode, boardServer.state.isRunning {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "qrcode")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.link)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan the pairing code once more on each phone")
                        .font(.system(size: 13, weight: .medium))
                    Text("The new code tells it to try \(node.preferredHost) when it is away from home. Phones also need the Tailscale app, signed in to this tailnet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Show Code…") {
                    NotificationCenter.default.post(name: .phoneAccessRequested, object: nil)
                }
            }
            .padding(14)
            .background(Theme.link.opacity(0.08), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.link.opacity(0.25)) }
        }
    }

    @ViewBuilder
    private var remoteStatus: some View {
        switch tailnet.status {
        case nil:
            StatusLine(color: .secondary, text: "Checking Tailscale…")
        case .notInstalled:
            StatusLine(color: .secondary, text: "Tailscale isn’t installed on this Mac")
        case .notConnected(let reason):
            StatusLine(color: Theme.warning, text: reason)
        case .connected(let node):
            if tailnet.isEnabled {
                StatusLine(color: Theme.running, text: "Reachable as \(node.preferredHost)" + (node.tailnet.map { " · \($0)" } ?? ""))
            } else {
                StatusLine(color: .secondary, text: "On your tailnet as \(node.preferredHost) · off")
            }
        }
    }

    private var tailscaleBadges: [(String, Bool)] {
        switch tailnet.status {
        case .connected: [("Recommended", true), ("Connected", false)]
        case .notConnected: [("Recommended", true), ("Not connected", false)]
        case .notInstalled: [("Recommended", true), ("Not installed", false)]
        case nil: [("Recommended", true)]
        }
    }

    private var mcpReachSubtitle: String {
        guard server.isEnabled else { return "Turn the MCP server on in Claude & MCP first." }
        switch server.remoteState {
        case .running: return "Claude Code on another Mac can work these boards. Still needs the token."
        case .failed(let message): return message
        default: return "Claude Code on another Mac can work these boards, with the token."
        }
    }

    private var phoneReachSubtitle: String {
        guard boardServer.state.isRunning else { return "Start Phone Access in Devices first." }
        return tailnet.phoneNode == nil
            ? "Your phone reaches this Mac off the Wi-Fi, with its pairing key."
            : "Listening on port \(TailnetAccess.phonePort) for your phone, with its pairing key."
    }

    private func routeCard(title: String, badges: [(String, Bool)], text: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            HStack(spacing: 4) {
                ForEach(badges, id: \.0) { badge in
                    Text(badge.0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badge.1 ? Theme.running : .secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background((badge.1 ? Theme.running : Color.secondary).opacity(0.15), in: .rect(cornerRadius: 4))
                }
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Theme.groupBox, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Theme.groupStroke, lineWidth: isSelected ? 2 : 1)
        }
    }

    private var installBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 16))
                .foregroundStyle(Theme.link)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install Tailscale to use Pitwall away from home")
                    .font(.system(size: 13, weight: .medium))
                Text("Install it on this Mac and on your phone, sign both in to the same tailnet, then come back here. It is free for personal use.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Link("Get Tailscale…", destination: Tailscale.downloadURL)
                Button(tailnet.isChecking ? "Checking…" : "Check Again") {
                    Task { await tailnet.refresh() }
                }
                .disabled(tailnet.isChecking)
            }
        }
        .padding(14)
        .background(Theme.link.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.link.opacity(0.25)) }
    }

    // MARK: - Devices

    @ViewBuilder
    private var devicesPane: some View {
        hero(
            symbol: "iphone",
            tint: Color(light: 0x30B0C7, dark: 0x30B0C7),
            title: "Phone Access",
            isOn: nil
        ) {
            if boardServer.state.isRunning {
                StatusLine(color: Theme.running,
                           text: "Serving on this network · \(boardServer.clients.count) connected")
            } else {
                StatusLine(color: .secondary, text: "Off")
            }
        } accessory: {
            Button("Set Up…") {
                NotificationCenter.default.post(name: .phoneAccessRequested, object: nil)
            }
        }

        Text("Your phone pairs with this Mac over the local network with a QR code. Sharing the board, the terminal and files are separate switches, set in Phone Access.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SettingsSection(title: "Connected devices") {
            SettingsGroup {
                if boardServer.clients.isEmpty {
                    Text("No device is connected right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(boardServer.clients.enumerated()), id: \.element.id) { index, client in
                    if index > 0 { GroupDivider() }
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name).font(.system(size: 13, weight: .medium))
                            Text("Connected \(client.connectedAt.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                }
            }
        }

        SettingsSection(title: "Notifications") {
            SettingsGroup {
                GroupRow(
                    title: "Tell me when someone else moves a card",
                    subtitle: "Claude or your phone. Your own drags stay quiet."
                ) {
                    Toggle("Notify on moves", isOn: $notifyOnMoves)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Pieces

    /// The card at the top of a pane: icon tile, title, live status, switch.
    private func hero<Status: View, Accessory: View>(
        symbol: String,
        tint: Color,
        title: String,
        isOn: Binding<Bool>?,
        @ViewBuilder status: () -> Status,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .bold))
                status()
            }
            Spacer(minLength: 12)
            accessory()
            if let isOn {
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .padding(16)
        .background(Theme.groupBox, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.groupStroke) }
    }

    private static func uptime(since date: Date) -> String {
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86_400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86_400) d"
    }
}

// MARK: - Building blocks

/// A bold 12 pt heading over a group, with an optional trailing note or control.
private struct SettingsSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                trailing()
            }
            content()
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

extension SettingsSection where Trailing == Text {
    init(title: String, trailing: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(
            title: title,
            trailing: { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary) },
            content: content
        )
    }
}

/// A rounded box with a hairline border — DevVault's group box.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Theme.groupBox, in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.groupStroke) }
    }
}

private struct GroupDivider: View {
    var body: some View {
        Rectangle().fill(Theme.groupStroke).frame(height: 1)
    }
}

/// Title and subtitle on the left, controls on the right — the row every
/// setting is.
private struct GroupRow<Controls: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            controls()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct StatusLine: View {
    let color: Color
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isError ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }
}

private struct Permission: View {
    let title: String
    let allowed: Bool

    init(_ title: String, allowed: Bool) {
        self.title = title
        self.allowed = allowed
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14))
                .foregroundStyle(allowed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(allowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if !allowed {
                Text("no tool for it")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
