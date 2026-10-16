//
//  CodeEditor.swift
//  workflow-manager
//
//  A file's text as an editor: drag-select across lines, type, ⌘Z, ⌘F, line
//  numbers, the same syntax colours the read-only preview used.
//
//  An `NSTextView` rather than SwiftUI text. The preview drew one `Text` per
//  line, so a selection could never cross a line — the same wall the old
//  terminal grid hit — and SwiftUI has no editor that highlights. TextKit 1 is
//  built by hand because the line-number ruler reads line fragments from
//  `NSLayoutManager`.
//
//  Code is not prose: no wrapping, no smart quotes or dashes, no spelling
//  underlines, no text replacement. Return keeps the line's indent, as every
//  code editor does.
//

import AppKit
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    /// The text to show. Only read when `loadToken` changes — every keystroke
    /// goes the other way, through `onChange`, so the view never fights its own
    /// edits.
    let text: String
    let loadToken: Int
    let language: SyntaxHighlighter.Language?
    var isEditable = true
    var onChange: (String) -> Void = { _ in }

    static let fontSize: CGFloat = 12
    /// Past this, colouring is skipped: highlighting re-runs on every edit, and
    /// a plain editor beats a laggy one.
    static let highlightLimit = 400_000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = context.coordinator
        textView.typingAttributes = Coordinator.baseAttributes

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.load(text, language: language)
        context.coordinator.loadedToken = loadToken
        textView.isEditable = isEditable
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.textView?.isEditable = isEditable
        if coordinator.loadedToken != loadToken {
            coordinator.loadedToken = loadToken
            coordinator.load(text, language: language)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRuler?
        var loadedToken = -1
        private var language: SyntaxHighlighter.Language?
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        static var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedSystemFont(ofSize: CodeEditor.fontSize, weight: .regular),
             .foregroundColor: NSColor.labelColor]
        }

        /// Replaces the whole text — a newly opened file, or one reloaded from
        /// disk. Keeps the caret and scroll where they were when the file is
        /// the same one coming back, which is what a reload looks like.
        func load(_ text: String, language: SyntaxHighlighter.Language?) {
            guard let textView, let storage = textView.textStorage else { return }
            self.language = language
            let selection = textView.selectedRanges
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.baseAttributes))
            textView.undoManager?.removeAllActions()
            let length = storage.length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
            highlight()
            ruler?.invalidateLines()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            ruler?.invalidateLines()
            // A beat after typing stops: colouring a long file per keystroke
            // would spend the frame on every key.
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = storage.string
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: CodeEditor.fontSize, weight: .regular),
                                 range: whole)
            if let language, storage.length <= CodeEditor.highlightLimit {
                for span in SyntaxHighlighter.spans(in: string, language: language) {
                    let range = NSRange(span.range, in: string)
                    guard NSMaxRange(range) <= storage.length else { continue }
                    storage.addAttribute(.foregroundColor, value: Self.color(for: span.token), range: range)
                    if span.token == .heading {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: CodeEditor.fontSize,
                                                                                         weight: .semibold), range: range)
                    }
                }
            }
            storage.endEditing()
        }

        /// The read-only preview's colours, so a file looks the same whether
        /// or not it is being edited.
        private static func color(for token: SyntaxHighlighter.Token) -> NSColor {
            switch token {
            case .plain:   .labelColor
            case .comment: .secondaryLabelColor
            case .string:  NSColor(red: 0.80, green: 0.36, blue: 0.36, alpha: 1)
            case .number:  NSColor(red: 0.42, green: 0.55, blue: 0.85, alpha: 1)
            case .keyword: NSColor(red: 0.68, green: 0.38, blue: 0.78, alpha: 1)
            case .heading: .labelColor
            }
        }
    }
}

/// Return keeps the indent of the line it was pressed on.
final class CodeTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0)).location
        var indent = ""
        var index = lineStart
        while index < min(caret, ns.length) {
            let character = ns.character(at: index)
            guard character == 32 || character == 9 else { break }
            indent.append(Character(UnicodeScalar(character)!))
            index += 1
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }
}

/// Line numbers down the left edge, drawn from the layout manager's line
/// fragments so a number sits on its line's first fragment.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Where each line starts, in UTF-16 offsets. Rebuilt on edit — one pass
    /// over the text is cheap next to laying it out.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func boundsChanged(_ note: Notification) {
        guard let clip = note.object as? NSClipView, clip === textView?.enclosingScrollView?.contentView else { return }
        needsDisplay = true
    }

    func invalidateLines() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var starts = [0]
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < ns.length || (index == ns.length && ns.length > 0 && ns.character(at: ns.length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let thickness = CGFloat(digits) * 7.5 + 16
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: CodeEditor.fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let origin = textView.textContainerOrigin
        let offset = convert(NSPoint.zero, from: textView).y

        // The first line that starts at or before the visible range.
        var line = max(0, (lineStarts.lastIndex { $0 <= characters.location }) ?? 0)
        let length = (textView.string as NSString).length
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characters) { break }
            let rect: NSRect
            if start >= length {
                rect = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: start)
                rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = rect.minY + origin.y + offset + (rect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            line += 1
        }
    }
}
