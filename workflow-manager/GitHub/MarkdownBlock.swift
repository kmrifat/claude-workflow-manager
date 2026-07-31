//
//  MarkdownBlock.swift
//  workflow-manager
//
//  Block-level Markdown parsing for issue bodies.
//
//  SwiftUI's `Text(markdown:)` only understands *inline* syntax, so a body
//  handed to it directly shows literal `###`, raw pipes for tables, and loses
//  fenced code entirely. This splits a body into blocks; inline formatting is
//  still delegated to AttributedString during rendering.
//
//  Deliberately free of SwiftUI so it stays testable on its own.
//

import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(kind: ListKind, indent: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    enum ListKind: Equatable {
        case bullet
        case numbered(String)
        case task(isDone: Bool)
    }
}

extension MarkdownBlock {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }

        func flushAll() {
            flushParagraph()
            flushQuote()
        }

        // GitHub bodies routinely arrive CRLF; a stray \r renders as a box.
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            // Fenced code first: nothing inside it is markup.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushAll()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // An indented block of four spaces is also code, but only when it
            // isn't continuing a list item.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            // A pipe table needs its separator row to be a table at all.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushAll()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count {
                    let row = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(tableCells(row))
                    cursor += 1
                }
                blocks.append(.table(header: header, rows: rows))
                index = cursor - 1
                continue
            }

            if let item = listItem(line) {
                flushAll()
                blocks.append(item)
                continue
            }

            paragraph.append(line)
        }

        // An unterminated fence still has to render, or the rest of the body
        // silently disappears.
        if inCode, !codeLines.isEmpty {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    // MARK: - Line kinds

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        // ATX headings require a space, so `#hashtag` is not a heading.
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// Takes the untrimmed line so nesting depth survives.
    private static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        // Two spaces per level is the common convention; tabs count as one level.
        let indent = min(
            3,
            leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        )
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let rest = trimmed.dropFirst(marker.count)
            let box = rest.prefix(3).lowercased()
            if box == "[ ]" || box == "[x]" {
                return .listItem(
                    kind: .task(isDone: box == "[x]"),
                    indent: indent,
                    text: rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
                )
            }
            return .listItem(kind: .bullet, indent: indent, text: String(rest))
        }

        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .listItem(
            kind: .numbered("\(digits)."),
            indent: indent,
            text: String(rest.dropFirst(2))
        )
    }

    /// `|---|:--:|` and friends — the row that turns pipes into a table.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "|-: \t".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
