//
//  NotesView.swift
//  ClaudeWMMobile
//
//  A card's notes, for reading: headings, lists, quotes and code panels laid
//  out as blocks (`MarkdownBlock`, shared with the Mac's issue view), and each
//  image drawn where its line is, fetched from the Mac by id.
//
//  `Text(markdown:)` alone would not do: it understands only inline syntax, so
//  `## What done looks like` would read as a line starting with two hashes.
//

import SwiftUI
import UIKit
import ClaudeWMWire

struct NotesView: View {
    let text: String
    let projectID: String
    let attachments: [WireAttachmentRef]
    let connection: BoardConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(NotesSegment.split(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                case .image(let alt, let target):
                    NotesImage(alt: alt, target: target, projectID: projectID,
                               ref: attachments.first { $0.id.caseInsensitiveCompare(target) == .orderedSame },
                               connection: connection)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Notes cut at their image lines: an image is a line of its own, so
/// everything between two of them is ordinary Markdown.
enum NotesSegment: Equatable {
    case markdown(String)
    /// `target` is an attachment id, or a `pending:` upload id.
    case image(alt: String, target: String)

    private static let imageLine = try! NSRegularExpression(
        pattern: "^\\s*!\\[([^\\]\\n]*)\\]\\((attachment|pending):([0-9A-Za-z-]+)\\)\\s*$"
    )

    static func split(_ text: String) -> [NotesSegment] {
        var segments: [NotesSegment] = []
        var run: [String] = []
        func flush() {
            let joined = run.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(joined)) }
            run = []
        }
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let match = imageLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                let scheme = ns.substring(with: match.range(at: 2))
                let id = ns.substring(with: match.range(at: 3))
                segments.append(.image(alt: ns.substring(with: match.range(at: 1)),
                                       target: scheme == PendingImage.scheme ? "\(scheme):\(id)" : id))
            } else {
                run.append(line)
            }
        }
        flush()
        return segments
    }
}

// MARK: - Blocks

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 6)
        case .paragraph(let text):
            Text(inline(text))
        case .listItem(let kind, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch kind {
                case .bullet:
                    Text("•").foregroundStyle(.tint)
                case .numbered(let number):
                    Text(number).foregroundStyle(.secondary).monospacedDigit()
                case .task(let isDone):
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Text(inline(text))
                    .strikethrough(kind == .task(isDone: true))
                    .foregroundStyle(kind == .task(isDone: true) ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(.separator)).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(header.indices, id: \.self) { Text(inline(header[$0])).bold() } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow { ForEach(rows[row].indices, id: \.self) { Text(inline(rows[row][$0])) } }
                    }
                }
                .font(.footnote)
            }
        case .rule:
            Divider()
        }
    }

    /// Inline Markdown, with code given a background: SwiftUI otherwise only
    /// changes its font, which in a note full of paths reads as random
    /// font switches.
    private func inline(_ text: String) -> AttributedString {
        var string = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = .system(.callout, design: .monospaced)
            string[run.range].backgroundColor = Color(.tertiarySystemFill)
        }
        return string
    }
}

// MARK: - Images

/// One image in the notes, fetched by id and drawn at its own shape.
struct NotesImage: View {
    let alt: String
    let target: String
    let projectID: String
    let ref: WireAttachmentRef?
    let connection: BoardConnection

    @State private var showsFull = false

    private var isPending: Bool { target.hasPrefix("\(PendingImage.scheme):") }
    private var uploadID: String { String(target.dropFirst(PendingImage.scheme.count + 1)) }

    private var image: UIImage? {
        isPending ? connection.localImages[uploadID]
                  : connection.image(target, in: projectID, maxEdge: 1200)
    }

    /// The widest it is drawn: its own size in points, as in the editor and on
    /// the Mac — a small screenshot is not blown up to the column.
    private var naturalWidth: CGFloat {
        if let image { return image.size.width * image.scale / 2 }
        if let ref, ref.width > 0 { return CGFloat(ref.width) / 2 }
        return .infinity
    }

    private var aspect: CGFloat {
        if let image, image.size.height > 0 { return image.size.width / image.size.height }
        if let ref, ref.height > 0 { return CGFloat(ref.width) / CGFloat(ref.height) }
        return 4 / 3
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { if !isPending { showsFull = true } }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 6) {
                            ProgressView()
                            Text(alt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
            }
        }
        .frame(maxWidth: naturalWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(alt))
        .fullScreenCover(isPresented: $showsFull) {
            FullImageView(attachmentID: target, projectID: projectID, alt: alt, connection: connection)
        }
    }
}

/// An image at full size, pinch to zoom.
private struct FullImageView: View {
    let attachmentID: String
    let projectID: String
    let alt: String
    let connection: BoardConnection
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Group {
                if let image = connection.image(attachmentID, in: projectID, maxEdge: nil) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }
                                                 .onEnded { _ in withAnimation { scale = 1 } })
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(alt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
