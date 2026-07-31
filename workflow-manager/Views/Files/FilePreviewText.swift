//
//  FilePreviewText.swift
//  workflow-manager
//
//  A file's text, highlighted, with line numbers.
//
//  Highlighting runs once per file on a background task and produces one
//  `AttributedString` per line. Doing it per render — or as one giant
//  attributed string — is what makes previews of a 5,000-line file stutter,
//  because the whole thing is re-laid-out on every scroll tick.
//

import SwiftUI

struct FilePreviewText: View {
    let text: String
    let url: URL

    @State private var lines: [Line] = []
    @State private var isHighlighting = false

    struct Line: Identifiable {
        let id: Int
        let number: Int
        let content: AttributedString
    }

    private static let fontSize: CGFloat = 11.5
    /// Past this, highlighting is skipped and the file is shown plain. The
    /// scanner is fast, but building attributed strings for a very long file
    /// is not, and a readable-but-plain preview beats a spinner.
    private static let highlightLineLimit = 8_000

    var body: some View {
        // Nested rather than a single `[.vertical, .horizontal]` scroll view:
        // that combination centres content narrower than the viewport, which is
        // exactly wrong for code. The inner horizontal scroll pinned `.leading`
        // keeps every line flush to the left, like an editor.
        ScrollView(.vertical) {
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(line.number)")
                                .font(.system(size: Self.fontSize, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: gutterWidth, alignment: .trailing)
                                .textSelection(.disabled)

                            Text(line.content)
                                .font(.system(size: Self.fontSize, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.vertical, 0.5)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isHighlighting, lines.isEmpty {
                ProgressView()
            }
        }
        .task(id: url) { await highlight() }
    }

    private var gutterWidth: CGFloat {
        let digits = max(2, String(lines.count).count)
        return CGFloat(digits) * 7.5
    }

    private func highlight() async {
        isHighlighting = true
        defer { isHighlighting = false }

        let source = text
        let language = SyntaxHighlighter.language(
            forExtension: url.pathExtension,
            filename: url.lastPathComponent
        )

        lines = await Task.detached(priority: .userInitiated) {
            Self.buildLines(from: source, language: language)
        }.value
    }

    /// Splits into lines and applies the spans that fall inside each.
    ///
    /// One pass over the spans alongside one pass over the lines — both are
    /// already in document order, so there is no searching.
    private static func buildLines(
        from source: String,
        language: SyntaxHighlighter.Language?
    ) -> [Line] {
        let rawLines = source.components(separatedBy: "\n")
        guard let language, rawLines.count <= highlightLineLimit else {
            return rawLines.enumerated().map { index, content in
                Line(id: index, number: index + 1, content: AttributedString(content))
            }
        }

        let spans = SyntaxHighlighter.spans(in: source, language: language)

        var result: [Line] = []
        result.reserveCapacity(rawLines.count)

        var lineStart = source.startIndex
        var spanIndex = 0

        for (index, raw) in rawLines.enumerated() {
            let lineEnd = source.index(lineStart, offsetBy: raw.count, limitedBy: source.endIndex)
                ?? source.endIndex
            var attributed = AttributedString(raw)

            // A span may start before this line (a block comment) and end after
            // it, so advance only past spans that are entirely behind us.
            var probe = spanIndex
            while probe < spans.count, spans[probe].range.lowerBound < lineEnd {
                let span = spans[probe]
                if span.range.upperBound > lineStart {
                    let clampedLower = max(span.range.lowerBound, lineStart)
                    let clampedUpper = min(span.range.upperBound, lineEnd)
                    if clampedLower < clampedUpper {
                        let offset = source.distance(from: lineStart, to: clampedLower)
                        let length = source.distance(from: clampedLower, to: clampedUpper)
                        apply(span.token, to: &attributed, offset: offset, length: length)
                    }
                }
                probe += 1
            }
            // Only skip spans that cannot touch any later line.
            while spanIndex < spans.count, spans[spanIndex].range.upperBound <= lineEnd {
                spanIndex += 1
            }

            result.append(Line(id: index, number: index + 1, content: attributed))

            // +1 for the newline that `components(separatedBy:)` removed.
            lineStart = source.index(lineEnd, offsetBy: 1, limitedBy: source.endIndex) ?? source.endIndex
        }
        return result
    }

    private static func apply(
        _ token: SyntaxHighlighter.Token,
        to attributed: inout AttributedString,
        offset: Int,
        length: Int
    ) {
        guard length > 0,
              let start = attributed.index(
                attributed.startIndex,
                offsetByCharacters: offset,
                limitedBy: attributed.endIndex
              ),
              let end = attributed.index(
                start,
                offsetByCharacters: length,
                limitedBy: attributed.endIndex
              )
        else { return }

        attributed[start..<end].foregroundColor = color(for: token)
        if token == .heading {
            attributed[start..<end].font = .system(
                size: fontSize,
                weight: .semibold,
                design: .monospaced
            )
        }
    }

    /// Semantic system colours rather than a fixed theme, so the preview stays
    /// legible in both appearances.
    private static func color(for token: SyntaxHighlighter.Token) -> Color {
        switch token {
        case .plain:   .primary
        case .comment: .secondary
        case .string:  Color(red: 0.80, green: 0.36, blue: 0.36)
        case .number:  Color(red: 0.42, green: 0.55, blue: 0.85)
        case .keyword: Color(red: 0.68, green: 0.38, blue: 0.78)
        case .heading: .primary
        }
    }
}

private extension AttributedString {
    func index(
        _ index: AttributedString.Index,
        offsetByCharacters distance: Int,
        limitedBy limit: AttributedString.Index
    ) -> AttributedString.Index? {
        characters.index(index, offsetBy: distance, limitedBy: limit)
    }
}
