//
//  IssueMarkdownView.swift
//  workflow-manager
//
//  Renders parsed Markdown blocks as a document rather than a text dump.
//
//  The details that make it read as *rendered* rather than raw: inline code
//  carries a tinted background instead of only switching font, headings have a
//  real size hierarchy with rules under the top two levels, links are tinted and
//  underlined, list bullets hang, and paragraphs breathe.
//

import SwiftUI

struct IssueMarkdownView: View {
    let markdown: String
    var accent: Color = .accentColor

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, accent: accent)
                    .padding(.top, topPadding(for: block, isFirst: index == 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Spacing lives on the *following* block so that consecutive list items
    /// stay tight while a heading gets real air above it.
    private func topPadding(for block: MarkdownBlock, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        switch block {
        case .heading(let level, _): return level <= 2 ? 20 : 16
        case .listItem:              return 4
        case .code, .table:          return 12
        case .rule:                  return 14
        default:                     return 11
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let accent: Color

    /// Roomier than the default. Cramped leading is most of what makes rendered
    /// prose look like a log dump.
    private static let bodySize: CGFloat = 13
    private static let lineSpacing: CGFloat = 3.5

    var body: some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 5) {
                styled(text)
                    .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                // GitHub rules off its top two heading levels; it does a lot of
                // the work of making a long body scannable.
                if level <= 2 {
                    Divider()
                }
            }

        case .paragraph(let text):
            styled(text)
                .font(.system(size: Self.bodySize))
                .lineSpacing(Self.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let kind, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                marker(kind)
                    .frame(minWidth: 14, alignment: .leading)
                styled(text)
                    .font(.system(size: Self.bodySize))
                    .lineSpacing(Self.lineSpacing)
                    .strikethrough(isCompletedTask(kind), color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 18)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.5))
                    .frame(width: 3)
                styled(text)
                    .font(.system(size: Self.bodySize))
                    .lineSpacing(Self.lineSpacing)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let text):
            codeBlock(language: language, text: text)

        case .table(let header, let rows):
            tableBlock(header: header, rows: rows)

        case .rule:
            Divider()
        }
    }

    // MARK: - Pieces

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 19
        case 2: 16.5
        case 3: 14.5
        default: 13
        }
    }

    @ViewBuilder
    private func marker(_ kind: MarkdownBlock.ListKind) -> some View {
        switch kind {
        case .bullet:
            Text("•")
                .font(.system(size: Self.bodySize, weight: .bold))
                .foregroundStyle(accent.opacity(0.8))
        case .numbered(let label):
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .task(let isDone):
            Image(systemName: isDone ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(isDone ? accent : Color.secondary)
        }
    }

    private func isCompletedTask(_ kind: MarkdownBlock.ListKind) -> Bool {
        if case .task(true) = kind { return true }
        return false
    }

    private func codeBlock(language: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
            }
            // Code must never re-wrap — it scrolls sideways instead.
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(2.5)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func tableBlock(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)

        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(header.indices.contains(column) ? header[column] : "", isHeader: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            cell(row.indices.contains(column) ? row[column] : "", isHeader: false)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func cell(_ text: String, isHeader: Bool) -> some View {
        styled(text)
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    private func styled(_ source: String) -> Text {
        Text(MarkdownInline.render(source, accent: accent))
    }
}

