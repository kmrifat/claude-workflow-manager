//
//  MarkdownInline.swift
//  workflow-manager
//
//  Inline Markdown, styled beyond what SwiftUI does on its own.
//
//  SwiftUI honours `inlinePresentationIntent` for bold, italics and code — but
//  code only becomes monospaced, with no background, so in a body dense with
//  paths and identifiers it reads as random font switches mid-sentence rather
//  than as code. Links get no colour either. Both are applied here, and that is
//  most of the difference between "raw" and "rendered".
//

import SwiftUI

enum MarkdownInline {
    static func render(_ source: String, accent: Color) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)

        // Ranges are collected first: mutating attributes while iterating runs
        // invalidates the run boundaries underneath the loop.
        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []

        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                codeRanges.append(run.range)
            }
            if run.link != nil {
                linkRanges.append(run.range)
            }
        }

        for range in codeRanges {
            attributed[range].font = .system(size: 12, design: .monospaced)
            attributed[range].backgroundColor = .secondary.opacity(0.16)
            attributed[range].foregroundColor = .primary
        }

        for range in linkRanges {
            attributed[range].foregroundColor = accent
            attributed[range].underlineStyle = .single
        }

        return attributed
    }

    /// Number of inline-code runs — used by tests to prove code spans survive
    /// parsing and get styled rather than being flattened into prose.
    static func codeRunCount(_ source: String, accent: Color = .accentColor) -> Int {
        render(source, accent: accent).runs.count {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
    }
}
