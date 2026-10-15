//
//  MarkdownStyler.swift
//  ClaudeWMWire
//
//  What each run of a card's notes should look like while it is being typed.
//  The card window styles Markdown in place, the way Notes styles its text:
//  a `## ` line gets bigger, `**word**` gets bold, a `- [ ]` line gets a round
//  checkbox. The text itself never stops being Markdown — the markers stay in
//  the string, faded — because the same notes are read by Claude, by `gh`,
//  and by the phone, all of which want Markdown, not a rich-text format of our
//  own.
//
//  Pure Foundation over `NSString` ranges, because the text view it feeds is
//  an `NSTextStorage` and counts in UTF-16. A separate pass from
//  `MarkdownBlock`, which *renders* Markdown for reading: this one has to
//  answer for every character of a half-typed document, and never reflows it.
//

import Foundation

public enum MarkdownStyle: Equatable, Sendable {
    /// A whole heading line, `#` to `######`.
    case heading(Int)
    /// Syntax the reader does not need to see at full strength: `##`, `**`,
    /// backticks, a link's `(url)`, fences.
    case marker
    case bold
    case italic
    case strikethrough
    case inlineCode
    /// Every line of a fenced block, fences included.
    case codeBlock
    /// A `>` line.
    case quote
    /// The `-`, `*` or `+` of a list item — drawn as a bullet.
    case bullet
    /// The `- [ ]` of a checklist item — drawn as a round checkbox.
    case checkbox(checked: Bool)
    /// The text of a ticked checklist item.
    case checkedText
    /// The visible text of `[text](url)`.
    case link
    /// A line that is only an image, `![alt](target)`. Drawn as the image,
    /// under its reference — the way Notes shows a pasted picture.
    case image(target: String)
    /// A list item's whole line, for its hanging indent. `marker` is how many
    /// UTF-16 units the bullet and its space take, and `depth` the nesting.
    case listItem(depth: Int, marker: Int)
}

public struct MarkdownSpan: Equatable, Sendable {
    public let range: NSRange
    public let style: MarkdownStyle

    public init(range: NSRange, style: MarkdownStyle) {
        self.range = range
        self.style = style
    }
}

public enum MarkdownStyler {

    public static func spans(in text: String) -> [MarkdownSpan] {
        let string = text as NSString
        var spans: [MarkdownSpan] = []
        var inFence = false

        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                spans.append(MarkdownSpan(range: lineRange, style: .codeBlock))
                spans.append(MarkdownSpan(range: lineRange, style: .marker))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(MarkdownSpan(range: lineRange, style: .codeBlock))
                return
            }
            spans += lineSpans(line, at: lineRange.location)
        }
        return spans
    }

    // MARK: - Lines

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    private static let quote = try! NSRegularExpression(pattern: "^>[ \\t]?")
    private static let checklist = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]\\[([ xX])\\][ \\t]")
    private static let bullet = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]")
    private static let ordered = try! NSRegularExpression(pattern: "^([ \\t]*)(\\d{1,9})[.)][ \\t]")
    private static let rule = try! NSRegularExpression(pattern: "^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private static let imageLine = try! NSRegularExpression(pattern: "^[ \\t]*!\\[[^\\]\\n]*\\]\\(([^)\\s]+)\\)[ \\t]*$")

    private static func lineSpans(_ line: String, at offset: Int) -> [MarkdownSpan] {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [MarkdownSpan] = []
        func span(_ range: NSRange, _ style: MarkdownStyle) {
            spans.append(MarkdownSpan(range: NSRange(location: range.location + offset, length: range.length), style: style))
        }

        if rule.firstMatch(in: line, range: whole) != nil {
            span(whole, .marker)
            return spans
        }
        if let match = imageLine.firstMatch(in: line, range: whole) {
            span(whole, .image(target: ns.substring(with: match.range(at: 1))))
            span(whole, .marker)
            return spans
        }

        // Where the inline pass starts: after whatever opened the line.
        var contentStart = 0

        if let match = heading.firstMatch(in: line, range: whole) {
            let level = match.range(at: 1).length
            span(whole, .heading(level))
            span(match.range, .marker)
            contentStart = match.range.length
        } else if let match = quote.firstMatch(in: line, range: whole) {
            span(whole, .quote)
            span(match.range, .marker)
            contentStart = match.range.length
        } else if let match = checklist.firstMatch(in: line, range: whole) {
            let indent = match.range(at: 1)
            let box = NSRange(location: match.range(at: 2).location,
                              length: NSMaxRange(match.range(at: 3)) + 1 - match.range(at: 2).location)
            let checked = ns.substring(with: match.range(at: 3)).lowercased() == "x"
            span(whole, .listItem(depth: depth(of: ns.substring(with: indent)), marker: match.range.length - indent.length))
            span(box, .checkbox(checked: checked))
            contentStart = match.range.length
            if checked, contentStart < ns.length {
                span(NSRange(location: contentStart, length: ns.length - contentStart), .checkedText)
            }
        } else if let match = bullet.firstMatch(in: line, range: whole) {
            let indent = match.range(at: 1)
            span(whole, .listItem(depth: depth(of: ns.substring(with: indent)), marker: match.range.length - indent.length))
            span(match.range(at: 2), .bullet)
            contentStart = match.range.length
        } else if let match = ordered.firstMatch(in: line, range: whole) {
            let indent = match.range(at: 1)
            span(whole, .listItem(depth: depth(of: ns.substring(with: indent)), marker: match.range.length - indent.length))
            contentStart = match.range.length
        }

        let content = NSRange(location: contentStart, length: ns.length - contentStart)
        for inline in inlineSpans(ns, in: content) {
            span(inline.range, inline.style)
        }
        return spans
    }

    /// Two spaces or one tab per level, the way editors indent Markdown lists.
    private static func depth(of indent: String) -> Int {
        let columns = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return columns / 2
    }

    // MARK: - Inline

    private static let code = try! NSRegularExpression(pattern: "(`+)(?=[^`])(.+?)(?<=[^`])\\1(?!`)")
    private static let link = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    private static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strike = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)~~")
    private static let italic = try! NSRegularExpression(
        pattern: "(?<![*\\w])(\\*|_)(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*\\w])"
    )

    /// Code first, then links, then emphasis — and nothing inside a code span
    /// or a link's URL is looked at again. That ordering is the whole design,
    /// for the reason `SyntaxHighlighter` gives: `**` inside backticks, or an
    /// underscore in a URL, is exactly what a bank of independent patterns
    /// gets wrong.
    private static func inlineSpans(_ line: NSString, in range: NSRange) -> [MarkdownSpan] {
        guard range.length > 0 else { return [] }
        let string = line as String
        var spans: [MarkdownSpan] = []
        var claimed: [NSRange] = []

        func isFree(_ r: NSRange) -> Bool {
            !claimed.contains { NSIntersectionRange($0, r).length > 0 }
        }

        for match in code.matches(in: string, range: range) where isFree(match.range) {
            let fence = match.range(at: 1).length
            spans.append(MarkdownSpan(range: match.range, style: .inlineCode))
            spans.append(MarkdownSpan(range: NSRange(location: match.range.location, length: fence), style: .marker))
            spans.append(MarkdownSpan(range: NSRange(location: NSMaxRange(match.range) - fence, length: fence), style: .marker))
            claimed.append(match.range)
        }

        for match in link.matches(in: string, range: range) where isFree(match.range) {
            let text = match.range(at: 1)
            spans.append(MarkdownSpan(range: NSRange(location: match.range.location, length: 1), style: .marker))
            spans.append(MarkdownSpan(range: text, style: .link))
            spans.append(MarkdownSpan(range: NSRange(location: NSMaxRange(text), length: NSMaxRange(match.range) - NSMaxRange(text)),
                                      style: .marker))
            // The URL is claimed; the link text can still carry emphasis.
            claimed.append(NSRange(location: NSMaxRange(text), length: NSMaxRange(match.range) - NSMaxRange(text)))
        }

        for (pattern, style) in [(bold, MarkdownStyle.bold), (strike, .strikethrough), (italic, .italic)] {
            for match in pattern.matches(in: string, range: range) {
                let fence = match.range(at: 1).length
                let open = NSRange(location: match.range.location, length: fence)
                let close = NSRange(location: NSMaxRange(match.range) - fence, length: fence)
                guard isFree(open), isFree(close) else { continue }
                spans.append(MarkdownSpan(range: match.range, style: style))
                spans.append(MarkdownSpan(range: open, style: .marker))
                spans.append(MarkdownSpan(range: close, style: .marker))
                claimed += [open, close]
            }
        }
        return spans
    }

    // MARK: - Editing

    /// What Return should insert on `line` to carry a list on, or nil when the
    /// line is not a list item. An item with nothing after its marker answers
    /// `.end` — Return on an empty bullet ends the list, as in Notes.
    public enum Continuation: Equatable, Sendable {
        case insert(String)
        case end(markerLength: Int)
    }

    public static func continuation(of line: String) -> Continuation? {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let match: NSTextCheckingResult
        let next: String

        if let m = checklist.firstMatch(in: line, range: whole) {
            match = m
            next = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + " [ ] "
        } else if let m = bullet.firstMatch(in: line, range: whole) {
            match = m
            next = ns.substring(with: m.range)
        } else if let m = ordered.firstMatch(in: line, range: whole) {
            match = m
            let number = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let separator = ns.substring(with: NSRange(location: NSMaxRange(m.range(at: 2)), length: 1))
            next = ns.substring(with: m.range(at: 1)) + "\(number + 1)" + separator + " "
        } else {
            return nil
        }

        let rest = ns.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? .end(markerLength: match.range.length) : .insert("\n" + next)
    }

    /// `line` with a checklist marker added, or taken off if it has one. A
    /// plain bullet becomes a checklist item rather than gaining a second
    /// marker.
    public static func togglingChecklist(_ line: String) -> String {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let m = checklist.firstMatch(in: line, range: whole) {
            return ns.substring(with: m.range(at: 1)) + ns.substring(from: m.range.length)
        }
        if let m = bullet.firstMatch(in: line, range: whole) {
            return ns.substring(with: m.range(at: 1)) + "- [ ] " + ns.substring(from: m.range.length)
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "- [ ] " + line.dropFirst(indent.count)
    }

    /// The same line with its checkbox flipped, or nil if it has none.
    public static func togglingCheckbox(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = checklist.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let box = m.range(at: 3)
        let checked = ns.substring(with: box).lowercased() == "x"
        return ns.replacingCharacters(in: box, with: checked ? " " : "x")
    }

    /// `line` set to a heading of `level`, or to body text with `level` 0.
    public static func settingHeading(_ line: String, level: Int) -> String {
        let ns = line as NSString
        var body = line
        if let m = heading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            body = ns.substring(from: m.range.length)
        }
        return level == 0 ? body : String(repeating: "#", count: level) + " " + body
    }
}
