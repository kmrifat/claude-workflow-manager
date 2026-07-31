//
//  GitHubIssueDetailSheet.swift
//  workflow-manager
//
//  One issue, in full. Read-only like everything else on the GitHub side —
//  nothing here writes back, so there is no Save and no editing affordance.
//
//  Shown as a popover anchored to the issue's card, so the board stays visible
//  behind it and clicking away dismisses it. It is still written to work as a
//  free-standing resizable panel (`presentation: .panel`) — issue bodies run
//  from one line to several screens, and that mode owns its own `size`, dragged
//  from the grip in the footer and clamped to the `maxSize` its host passes
//  down. In `.popover` the size is fixed and the chrome comes from the popover.
//

import SwiftUI

struct GitHubIssueDetailSheet: View {
    let issue: GitHubIssue
    var repositorySlug: String?
    var accent: Color = .accentColor
    var branchSummary: GitReader.BranchSummary?

    /// The title of the card tracking this issue, when one exists. A `String`
    /// rather than a `WorkItem` so this panel stays free of SwiftData — it takes
    /// only value types, which is what makes it previewable in isolation.
    var linkedItemTitle: String?
    /// The board's columns, as `(id, name)`. Empty when there is no board to
    /// add to, which hides the control entirely.
    var columns: [(id: UUID, name: String)] = []
    var onAddToBoard: (UUID) -> Void = { _ in }

    /// How the panel is being hosted.
    ///
    /// A popover supplies its own chrome, dismissal and Escape handling, so the
    /// backdrop-era affordances — the resize grip, the shadow, the rounded
    /// background, the Done button — would be duplicates inside one.
    enum Presentation: Sendable {
        case panel
        case popover
    }

    var presentation: Presentation = .panel

    /// The room the host has for the panel (its bounds minus a margin). The
    /// panel never grows past this, so it can't spill off the window.
    var maxSize: CGSize = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)

    /// Dismisses the modal. Injected because there is no `.sheet` presentation
    /// to drive `@Environment(\.dismiss)`.
    var onClose: () -> Void = {}

    private static let minSize = CGSize(width: 480, height: 360)
    private static let idealSize = CGSize(width: 760, height: 620)
    /// Fixed, and narrower than the panel: a popover is anchored to a card in a
    /// 300pt column, so a 760pt-wide one would cover the board it came from.
    private static let popoverSize = CGSize(width: 460, height: 560)

    @State private var size = GitHubIssueDetailSheet.idealSize
    /// The panel size when a resize drag began, so translation stays absolute.
    @State private var dragStartSize: CGSize?

    private var clampedSize: CGSize {
        if presentation == .popover { return Self.popoverSize }
        let minS = Self.minSize
        return CGSize(
            width: min(max(size.width, minS.width), max(maxSize.width, minS.width)),
            height: min(max(size.height, minS.height), max(maxSize.height, minS.height))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadata

                    if !issue.labels.isEmpty {
                        labelsSection
                    }

                    if let branchSummary {
                        BranchSummarySection(summary: branchSummary)
                    }

                    Divider()

                    if issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .italic()
                    } else {
                        IssueMarkdownView(markdown: issue.body, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: clampedSize.width, height: clampedSize.height)
        // A popover already draws its own background, corners and shadow, and
        // handles Escape itself.
        .background(presentation == .panel ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: presentation == .panel ? 12 : 0))
        .clipShape(.rect(cornerRadius: presentation == .panel ? 12 : 0))
        .shadow(radius: presentation == .panel ? 24 : 0, y: presentation == .panel ? 8 : 0)
        .onExitCommand(perform: onClose)
    }

    /// Drives the bottom-right resize grip. The panel is centred by its host, so
    /// each edge moves by half of any size change — doubling the translation
    /// keeps the corner tracking the cursor.
    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragStartSize ?? clampedSize
                if dragStartSize == nil { dragStartSize = base }
                size = CGSize(
                    width: base.width + value.translation.width * 2,
                    height: base.height + value.translation.height * 2
                )
            }
            .onEnded { _ in
                size = clampedSize
                dragStartSize = nil
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            stateBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text("\(repositorySlug ?? "") #\(issue.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var stateBadge: some View {
        Label(issue.isOpen ? "Open" : "Closed", systemImage: issue.isOpen ? "circle.dotted" : "checkmark.circle")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (issue.isOpen ? Color.green : Color.purple).opacity(0.18),
                in: .capsule
            )
            .foregroundStyle(issue.isOpen ? Color.green : Color.purple)
            .fixedSize()
    }

    // MARK: - Sections

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            if let author = issue.author {
                row("Author", systemImage: "person") {
                    Text(author.displayName)
                    + Text(author.displayName == author.login ? "" : "  @\(author.login)")
                        .foregroundColor(.secondary)
                }
            }

            row("Assignees", systemImage: "person.2") {
                Text(
                    issue.assignees.isEmpty
                        ? "Unassigned"
                        : issue.assignees.map(\.login).joined(separator: ", ")
                )
                .foregroundColor(issue.assignees.isEmpty ? .secondary : .primary)
            }

            if let milestone = issue.milestone {
                row("Milestone", systemImage: "flag") { Text(milestone.title) }
            }

            row("Opened", systemImage: "calendar") {
                Text(issue.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            row("Updated", systemImage: "clock") {
                Text(issue.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.system(size: 12))
    }

    private func row(
        _ title: String,
        systemImage: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
                .textSelection(.enabled)
        }
    }

    private var labelsSection: some View {
        // Wraps rather than clipping: issues routinely carry more labels than
        // fit on one line.
        FlowLayout(spacing: 5) {
            ForEach(issue.labels) { label in
                Text(label.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(label.swiftUIColor.opacity(0.18), in: .capsule)
                    .foregroundStyle(label.swiftUIColor)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Link(destination: issue.url) {
                Label("Open on GitHub", systemImage: "arrow.up.forward.square")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.url.absoluteString, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }

            if let linkedItemTitle {
                Label("Tracked as “\(linkedItemTitle)”", systemImage: BoardViewMode.board.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            } else if !columns.isEmpty {
                Menu {
                    ForEach(columns, id: \.id) { column in
                        Button(column.name) { onAddToBoard(column.id) }
                    }
                } label: {
                    Label("Add to Board", systemImage: "plus.rectangle.on.rectangle")
                }
                .fixedSize()
            }

            Spacer()

            // A popover is dismissed by clicking away or pressing Escape, and
            // cannot be resized by dragging a corner.
            if presentation == .panel {
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)

                resizeGrip
            }
        }
        .padding(12)
    }

    /// The corner handle that resizes the panel. Lives in the footer so it never
    /// fights the "Done" button for the bottom-right corner.
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
            .gesture(resizeGesture)
            .help("Drag to resize")
    }
}

/// Lays subviews out left to right, wrapping to a new line when the next one
/// would overflow the proposed width.
///
/// `HStack` cannot do this — it clips or compresses instead — and issues
/// routinely carry more labels than fit on one line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    struct Cache {
        var rows: [[Int]] = []
        var size: CGSize = .zero
        var width: CGFloat = -1
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        layout(width: width, subviews: subviews, cache: &cache)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        layout(width: bounds.width, subviews: subviews, cache: &cache)

        var y = bounds.minY
        for row in cache.rows {
            var x = bounds.minX
            let height = row
                .map { subviews[$0].sizeThatFits(.unspecified).height }
                .max() ?? 0

            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    /// Recomputed only when the available width changes — `sizeThatFits` and
    /// `placeSubviews` are both called every pass, and the row breakdown is the
    /// expensive part.
    private func layout(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        cache.width = width

        var rows: [[Int]] = []
        var row: [Int] = []
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // Never wrap on the first item of a row: one subview wider than the
            // whole container still has to go somewhere.
            if !row.isEmpty, x + size.width > width {
                rows.append(row)
                maxWidth = max(maxWidth, x - spacing)
                totalHeight += rowHeight + spacing
                row = []
                x = 0
                rowHeight = 0
            }
            row.append(index)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        if !row.isEmpty {
            rows.append(row)
            maxWidth = max(maxWidth, x - spacing)
            totalHeight += rowHeight
        }

        cache.rows = rows
        cache.size = CGSize(
            width: width.isFinite ? min(maxWidth, width) : maxWidth,
            height: totalHeight
        )
    }
}
