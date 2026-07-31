//
//  SyntaxHighlighter.swift
//  workflow-manager
//
//  A deliberately small highlighter: enough to read code by, not a parser.
//
//  It works in one left-to-right pass over the characters, classifying spans as
//  comment, string, number, keyword or plain. That ordering is the whole design
//  — comments and strings are consumed *first*, so a `//` inside a string
//  literal, or the word `class` inside a comment, cannot be mis-coloured. A
//  bank of regular expressions applied independently gets both of those wrong,
//  which is what makes naive highlighters look broken on exactly the lines you
//  are trying to read.
//
//  It does not know about types, scopes, generics or interpolation. It is not
//  supposed to.
//
//  Pure Foundation and no SwiftUI, like `MarkdownBlock`, so the scanner can be
//  exercised on its own.
//

import Foundation

nonisolated enum SyntaxHighlighter {

    enum Token: Equatable, Sendable {
        case plain
        case comment
        case string
        case number
        case keyword
        /// Markdown headings, and anything else worth showing as a title.
        case heading
    }

    struct Span: Equatable, Sendable {
        var range: Range<String.Index>
        var token: Token
    }

    struct Language: Sendable {
        var lineComment: [String]
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [Character]
        /// Triple-quoted or otherwise multi-line string forms.
        var multilineString: [String]
        var keywords: Set<String>
        var isMarkdown = false
        var supportsNumbers = true
    }

    // MARK: - Detection

    static func language(forExtension ext: String, filename: String = "") -> Language? {
        let name = filename.lowercased()
        // Files that are recognised by name rather than extension.
        if name == "makefile" || name == "dockerfile" || name == ".gitignore" {
            return .shellLike
        }

        switch ext.lowercased() {
        case "swift":                       return .swift
        case "js", "jsx", "mjs", "cjs",
             "ts", "tsx":                   return .javascript
        case "json":                        return .json
        case "md", "markdown":              return .markdown
        case "py":                          return .python
        case "sh", "bash", "zsh", "fish":   return .shellLike
        case "yml", "yaml", "toml":         return .configuration
        case "rb":                          return .ruby
        case "go":                          return .go
        case "rs":                          return .rust
        case "java", "kt", "kts":           return .java
        case "c", "h", "cpp", "cc", "hpp",
             "m", "mm":                     return .cLike
        case "html", "xml", "svg":          return .markup
        case "css", "scss", "less":         return .css
        case "sql":                         return .sql
        default:                            return nil
        }
    }

    // MARK: - Scanning

    /// Classifies `text`. Returns only non-plain spans, in order.
    static func spans(in text: String, language: Language) -> [Span] {
        if language.isMarkdown { return markdownSpans(in: text) }

        var spans: [Span] = []
        var index = text.startIndex
        var wordStart: String.Index?

        func flushWord(_ end: String.Index) {
            guard let start = wordStart else { return }
            wordStart = nil
            let word = String(text[start..<end])
            if language.keywords.contains(word) {
                spans.append(Span(range: start..<end, token: .keyword))
            } else if language.supportsNumbers, isNumeric(word) {
                spans.append(Span(range: start..<end, token: .number))
            }
        }

        while index < text.endIndex {
            let character = text[index]

            // Identifiers and numbers accumulate until a separator.
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                if wordStart == nil { wordStart = index }
                index = text.index(after: index)
                continue
            }
            flushWord(index)

            // Multi-line strings before single, so `"""` is not read as `"`.
            if let (end, delimiter) = matchAny(language.multilineString, in: text, at: index) {
                let closeAt = find(delimiter, in: text, from: end) ?? text.endIndex
                let stop = closeAt == text.endIndex
                    ? text.endIndex
                    : text.index(closeAt, offsetBy: delimiter.count, limitedBy: text.endIndex) ?? text.endIndex
                spans.append(Span(range: index..<stop, token: .string))
                index = stop
                continue
            }

            // Comments before strings: a `#` in shell starts a comment even
            // though `#` is unremarkable elsewhere.
            if let (end, _) = matchAny(language.lineComment, in: text, at: index) {
                _ = end
                let stop = find("\n", in: text, from: index) ?? text.endIndex
                spans.append(Span(range: index..<stop, token: .comment))
                index = stop
                continue
            }

            if let block = language.blockComment,
               text[index...].hasPrefix(block.open) {
                let searchFrom = text.index(index, offsetBy: block.open.count, limitedBy: text.endIndex) ?? text.endIndex
                let closeAt = find(block.close, in: text, from: searchFrom)
                let stop = closeAt.flatMap {
                    text.index($0, offsetBy: block.close.count, limitedBy: text.endIndex)
                } ?? text.endIndex
                spans.append(Span(range: index..<stop, token: .comment))
                index = stop
                continue
            }

            if language.stringDelimiters.contains(character) {
                let stop = endOfString(in: text, from: index, delimiter: character)
                spans.append(Span(range: index..<stop, token: .string))
                index = stop
                continue
            }

            index = text.index(after: index)
        }
        flushWord(text.endIndex)

        return spans
    }

    // MARK: - Helpers

    /// Walks to the closing quote, honouring backslash escapes and refusing to
    /// run past the end of the line — an unterminated quote should colour one
    /// line, not the rest of the file.
    private static func endOfString(
        in text: String,
        from start: String.Index,
        delimiter: Character
    ) -> String.Index {
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if character == "\n" { return index }
            index = text.index(after: index)
            if character == delimiter { return index }
        }
        return text.endIndex
    }

    private static func matchAny(
        _ candidates: [String],
        in text: String,
        at index: String.Index
    ) -> (end: String.Index, match: String)? {
        for candidate in candidates where text[index...].hasPrefix(candidate) {
            let end = text.index(index, offsetBy: candidate.count, limitedBy: text.endIndex) ?? text.endIndex
            return (end, candidate)
        }
        return nil
    }

    private static func find(
        _ needle: String,
        in text: String,
        from index: String.Index
    ) -> String.Index? {
        guard index <= text.endIndex else { return nil }
        return text.range(of: needle, range: index..<text.endIndex)?.lowerBound
    }

    private static func isNumeric(_ word: String) -> Bool {
        guard let first = word.first, first.isNumber else { return false }
        return true
    }

    /// Markdown is line-oriented, so it gets its own small pass rather than
    /// being forced through the keyword scanner.
    private static func markdownSpans(in text: String) -> [Span] {
        var spans: [Span] = []
        var inFence = false

        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) {
            _, range, _, _ in
            let line = text[range]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                spans.append(Span(range: range, token: .comment))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(Span(range: range, token: .string))
                return
            }
            if trimmed.hasPrefix("#") {
                spans.append(Span(range: range, token: .heading))
                return
            }
            if trimmed.hasPrefix(">") {
                spans.append(Span(range: range, token: .comment))
                return
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                // Colour the bullet only, so the text stays readable.
                let bulletEnd = text.index(range.lowerBound, offsetBy: line.count - trimmed.count + 1)
                spans.append(Span(range: range.lowerBound..<bulletEnd, token: .keyword))
                return
            }
        }
        return spans
    }
}

// MARK: - Languages

extension SyntaxHighlighter.Language {
    private static let cKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "goto", "sizeof", "struct", "union", "enum",
        "typedef", "static", "const", "void", "int", "char", "float", "double",
        "long", "short", "unsigned", "signed", "extern", "inline", "volatile",
    ]

    static let swift = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        multilineString: ["\"\"\""],
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break",
            "case", "catch", "class", "continue", "default", "defer", "deinit",
            "do", "else", "enum", "extension", "fallthrough", "false", "final",
            "for", "func", "guard", "if", "import", "in", "init", "inout",
            "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated",
            "open", "operator", "private", "protocol", "public", "repeat",
            "return", "self", "Self", "some", "static", "struct", "subscript",
            "super", "switch", "throw", "throws", "true", "try", "typealias",
            "var", "where", "while", "willSet", "didSet", "get", "set",
            "@MainActor", "@Observable", "@State", "@Model",
        ]
    )

    static let javascript = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        multilineString: [],
        keywords: [
            "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else", "export",
            "extends", "false", "finally", "for", "from", "function", "if",
            "implements", "import", "in", "instanceof", "interface", "let",
            "new", "null", "of", "return", "static", "super", "switch", "this",
            "throw", "true", "try", "type", "typeof", "undefined", "var", "void",
            "while", "yield", "enum", "readonly", "as", "declare", "namespace",
        ]
    )

    static let json = Self(
        lineComment: [],
        blockComment: nil,
        stringDelimiters: ["\""],
        multilineString: [],
        keywords: ["true", "false", "null"]
    )

    static let markdown = Self(
        lineComment: [],
        blockComment: nil,
        stringDelimiters: [],
        multilineString: [],
        keywords: [],
        isMarkdown: true
    )

    static let python = Self(
        lineComment: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        multilineString: ["\"\"\"", "'''"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class",
            "continue", "def", "del", "elif", "else", "except", "False",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "None", "nonlocal", "not", "or", "pass", "raise",
            "return", "True", "try", "while", "with", "yield", "self",
        ]
    )

    static let shellLike = Self(
        lineComment: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
            "done", "case", "esac", "function", "return", "export", "local",
            "readonly", "source", "echo", "cd", "set", "unset", "in",
        ]
    )

    static let configuration = Self(
        lineComment: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: ["true", "false", "null", "yes", "no", "on", "off"]
    )

    static let ruby = Self(
        lineComment: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: [
            "def", "end", "class", "module", "if", "elsif", "else", "unless",
            "case", "when", "while", "until", "do", "begin", "rescue", "ensure",
            "return", "yield", "self", "nil", "true", "false", "require",
            "attr_accessor", "attr_reader", "attr_writer",
        ]
    )

    static let go = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "`"],
        multilineString: [],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select",
            "struct", "switch", "type", "var", "nil", "true", "false",
        ]
    )

    static let rust = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        multilineString: [],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate",
            "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl",
            "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
            "return", "self", "Self", "static", "struct", "super", "trait",
            "true", "type", "unsafe", "use", "where", "while",
        ]
    )

    static let java = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        multilineString: ["\"\"\""],
        keywords: cKeywords.union([
            "abstract", "boolean", "catch", "class", "extends", "final",
            "finally", "implements", "import", "instanceof", "interface",
            "native", "new", "null", "package", "private", "protected",
            "public", "super", "synchronized", "this", "throw", "throws",
            "transient", "true", "false", "try", "val", "var", "fun", "object",
            "companion", "data", "when", "is", "override", "suspend",
        ])
    )

    static let cLike = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: cKeywords.union([
            "class", "namespace", "template", "typename", "public", "private",
            "protected", "virtual", "override", "new", "delete", "this",
            "nullptr", "true", "false", "using", "auto", "constexpr",
            "#include", "#define", "#import", "@interface", "@implementation",
        ])
    )

    static let markup = Self(
        lineComment: [],
        blockComment: ("<!--", "-->"),
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: [],
        supportsNumbers: false
    )

    static let css = Self(
        lineComment: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        multilineString: [],
        keywords: [
            "important", "media", "import", "keyframes", "supports", "charset",
            "font-face", "root", "var", "calc",
        ]
    )

    static let sql = Self(
        lineComment: ["--"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["'", "\""],
        multilineString: [],
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
            "SET", "DELETE", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "JOIN",
            "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER",
            "HAVING", "LIMIT", "OFFSET", "AND", "OR", "NOT", "NULL", "PRIMARY",
            "KEY", "FOREIGN", "REFERENCES", "AS", "DISTINCT", "UNION",
            "select", "from", "where", "insert", "update", "delete", "create",
        ]
    )
}
