//
//  MarkdownTextView.swift
//  workflow-manager
//
//  The card window's notes: Markdown, styled as it is typed, in the manner of
//  Notes. `MarkdownStyler` decides what each run is; this file only turns that
//  into attributes and draws the three things attributes cannot — a bullet in
//  place of `-`, a round checkbox in place of `- [ ]`, and the panel behind a
//  code block or the bar beside a quote.
//
//  An `NSTextView`, not a SwiftUI `TextEditor`: `TextEditor` cannot style a
//  range, draw behind one, or say where a click landed in the text. It runs on
//  TextKit 1 for the same reason — `NSLayoutManager` is where glyph-level
//  drawing lives, and its line fragments are what a code panel is built from.
//
//  It does not scroll. The card window scrolls the whole page — title, fields,
//  notes, subtasks — so this view reports its height to SwiftUI instead.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the window's toolbar act on the notes: the formatting buttons live
/// outside the text view but have to edit inside it.
@MainActor
final class MarkdownEditorController {
    fileprivate weak var textView: MarkdownNSTextView?

    var isAttached: Bool { textView != nil }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func toggleBold() { textView?.toggleWrap("**") }
    func toggleItalic() { textView?.toggleWrap("*") }
    func toggleStrikethrough() { textView?.toggleWrap("~~") }
    func toggleInlineCode() { textView?.toggleWrap("`") }
    func toggleChecklist() { textView?.transformLines(MarkdownStyler.togglingChecklist) }
    func setHeading(_ level: Int) { textView?.transformLines { MarkdownStyler.settingHeading($0, level: level) } }
    func insertBulletList() { textView?.transformLines { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : "- " + $0 } }
    func insertQuote() { textView?.transformLines { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : "> " + $0 } }
    func insertCodeBlock() { textView?.insertCodeBlock() }
    func insertLink() { textView?.insertLink() }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var controller: MarkdownEditorController?
    /// Up from the first line: the window moves focus back to the title.
    var onExitTop: (() -> Void)?
    /// The picture for an image line's target (`attachment:<uuid>`), if any.
    var imageProvider: ((String) -> NSImage?)?
    /// Stores pasted or dropped image bytes and returns the Markdown that
    /// refers to them, or nil if they are not an image.
    var onInsertImage: ((Data, String?) -> String?)?
    /// A double-click on an image.
    var onOpenImage: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownNSTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        layout.imageProvider = imageProvider
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        // Width follows the frame by hand (`setFrameSize`): `sizeThatFits`
        // measures at widths SwiftUI only proposes, and tracking would leave
        // the container at whichever was asked last.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = MarkdownNSTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        storage.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        // SwiftUI owns the frame (`sizeThatFits`). Left resizable, the text
        // view shrank itself back to its used text after every layout — one
        // line when empty — and clipped a two-line placeholder.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.smartInsertDeleteEnabled = false
        view.insertionPointColor = NSColor.controlAccentColor
        view.typingAttributes = MarkdownTheme.body
        view.placeholder = placeholder
        view.onExitTop = onExitTop
        view.onInsertImage = onInsertImage
        view.onOpenImage = onOpenImage
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let storage = view.textStorage else { return }
            coordinator?.restyle(storage)
        }

        view.string = text
        context.coordinator.restyle(storage)
        controller?.textView = view
        return view
    }

    func updateNSView(_ view: MarkdownNSTextView, context: Context) {
        context.coordinator.parent = self
        view.placeholder = placeholder
        view.onExitTop = onExitTop
        view.onInsertImage = onInsertImage
        view.onOpenImage = onOpenImage
        (view.layoutManager as? MarkdownLayoutManager)?.imageProvider = imageProvider
        controller?.textView = view
        // Only an outside change — another window, the phone — replaces the
        // text. Our own keystrokes come back through the binding unchanged,
        // and replacing on those would throw the caret to the end.
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text
            if let storage = view.textStorage { context.coordinator.restyle(storage) }
            let length = (text as NSString).length
            view.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? max(view.bounds.width, 600)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let current = container.size
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var used = layout.usedRect(for: container).height
        if view.bounds.width > 0 { container.size = current }
        // An empty document is as tall as its placeholder, and never less than
        // a line to click into.
        if view.string.isEmpty, !view.placeholder.isEmpty {
            used = (view.placeholder as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: MarkdownTheme.body
            ).height
        }
        return CGSize(width: width, height: max(ceil(used), MarkdownTheme.bodyLineHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }

        nonisolated func textStorage(
            _ storage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { restyle(storage) }
        }

        /// Restyles the whole document. Cards are short — a few hundred lines
        /// at most — and a fenced block opened on line 3 changes line 300, so
        /// a partial pass would need the same full scan to know where to stop.
        func restyle(_ storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes(MarkdownTheme.body, range: full)
            let width = storage.layoutManagers.first?.textContainers.first?.size.width ?? 600
            for span in MarkdownStyler.spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
                if case .image(let target) = span.style {
                    MarkdownTheme.applyImage(target, image: parent.imageProvider?(target), width: width,
                                             range: span.range, to: storage)
                } else {
                    MarkdownTheme.apply(span, to: storage)
                }
            }
            let string = storage.string as NSString
            string.enumerateSubstrings(in: full, options: .byLines) { line, range, enclosing, _ in
                // Not inside a code block, where a blank line is content.
                guard line?.trimmingCharacters(in: .whitespaces).isEmpty == true, enclosing.length > 0,
                      storage.attribute(.markdownCodeBlock, at: enclosing.location, effectiveRange: nil) == nil
                else { return }
                storage.addAttribute(.paragraphStyle, value: MarkdownTheme.blankLine, range: enclosing)
            }
        }
    }
}

// MARK: - Theme

/// Sizes follow design/ClaudeWM.fig › C02: 15 pt body, headings at 24/20/17.
@MainActor
enum MarkdownTheme {
    static let bodySize: CGFloat = 15
    static var bodyLineHeight: CGFloat { ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading) * 1.2 }

    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 2
        return style
    }

    /// A blank line separates blocks; at full height on top of paragraph
    /// spacing it reads as a gap. Notes spaces blocks at about half a line.
    static var blankLine: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 9
        style.maximumLineHeight = 9
        return style
    }

    static var body: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 24, weight: .bold)
        case 2: .systemFont(ofSize: 20, weight: .bold)
        case 3: .systemFont(ofSize: 17, weight: .semibold)
        default: .systemFont(ofSize: bodySize, weight: .semibold)
        }
    }

    static func apply(_ span: MarkdownSpan, to storage: NSTextStorage) {
        let range = span.range
        switch span.style {
        case .heading(let level):
            storage.addAttribute(.font, value: headingFont(level), range: range)
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.1
            style.paragraphSpacing = 4
            style.paragraphSpacingBefore = level <= 2 ? 4 : 2
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        case .marker:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .bold:
            convert(storage, range, adding: .boldFontMask)
        case .italic:
            convert(storage, range, adding: .italicFontMask)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .inlineCode:
            storage.addAttribute(.font, value: monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 1, green: 0.54, blue: 0.40, alpha: 1)
                    : NSColor(srgbRed: 0.75, green: 0.22, blue: 0.05, alpha: 1)
            }, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: range)
        case .codeBlock:
            storage.addAttribute(.font, value: monoFont, range: range)
            storage.addAttribute(.markdownCodeBlock, value: true, range: range)
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.15
            style.firstLineHeadIndent = MarkdownLayoutManager.codeInset
            style.headIndent = MarkdownLayoutManager.codeInset
            style.tailIndent = -MarkdownLayoutManager.codeInset
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            storage.addAttribute(.markdownQuote, value: true, range: range)
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 6
            style.firstLineHeadIndent = 14
            style.headIndent = 14
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        case .bullet:
            storage.addAttribute(.markdownBullet, value: true, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        case .checkbox(let checked):
            storage.addAttribute(.markdownCheckbox, value: checked, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            // Monospaced, hidden: `[x]` and `[ ]` take the same width, so
            // ticking an item does not shift its text.
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular),
                                 range: range)
        case .checkedText:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .image:
            // Laid out by `applyImage`, which needs the picture and the width.
            break
        case .listItem(let depth, let marker):
            // A hanging indent, so wrapped lines line up with the text and not
            // with the bullet.
            let prefix = (storage.string as NSString).substring(
                with: NSRange(location: range.location, length: min(range.length, depth * 2 + marker))
            )
            let markerWidth = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 3
            style.headIndent = markerWidth
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// An image line: its reference, small and faded, with room below for the
    /// picture, which `MarkdownLayoutManager` draws there. Shown at most at
    /// its own size in points — a screenshot from a Retina display is half its
    /// pixel width — never wider than the column, and never taller than 480.
    static func applyImage(_ target: String, image: NSImage?, width: CGFloat, range: NSRange, to storage: NSTextStorage) {
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: range)
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let size = displaySize(of: image, width: width)
        storage.addAttribute(.markdownImage, value: target, range: range)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = size.height + 12
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    static func displaySize(of image: NSImage, width: CGFloat) -> CGSize {
        let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        let natural = pixels.flatMap { $0.width > 0 ? CGSize(width: $0.width / 2, height: $0.height / 2) : nil }
            ?? image.size
        var size = natural
        if size.width > width { size = CGSize(width: width, height: width * natural.height / natural.width) }
        if size.height > 480 { size = CGSize(width: 480 * natural.width / natural.height, height: 480) }
        return CGSize(width: floor(size.width), height: floor(size.height))
    }

    private static func convert(_ storage: NSTextStorage, _ range: NSRange, adding trait: NSFontTraitMask) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = (value as? NSFont) ?? bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
        }
    }
}

extension NSAttributedString.Key {
    static let markdownBullet = NSAttributedString.Key("pitwall.markdownBullet")
    static let markdownCheckbox = NSAttributedString.Key("pitwall.markdownCheckbox")
    static let markdownCodeBlock = NSAttributedString.Key("pitwall.markdownCodeBlock")
    static let markdownQuote = NSAttributedString.Key("pitwall.markdownQuote")
    static let markdownImage = NSAttributedString.Key("pitwall.markdownImage")
}

// MARK: - Drawing

/// Draws what the text cannot carry: bullets, checkboxes, the code panel and
/// the quote bar. The characters underneath stay in the string — they are
/// coloured clear, so selection, copy and the caret still see real Markdown.
final class MarkdownLayoutManager: NSLayoutManager {
    static let codeInset: CGFloat = 12

    var imageProvider: ((String) -> NSImage?)?
    /// Where each image was last drawn, in container coordinates, so a
    /// double-click can find it.
    private(set) var imageFrames: [(rect: NSRect, target: String)] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // One rounded panel per fenced block. Each line carries the attribute
        // but the newlines between them do not, so the runs come back one per
        // line and are joined here.
        var panels: [NSRect] = []
        storage.enumerateAttribute(.markdownCodeBlock, in: characters) { value, run, _ in
            guard value != nil else { return }
            var rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
            rect.origin.x = origin.x
            rect.size.width = container.size.width
            rect = rect.offsetBy(dx: 0, dy: origin.y)
            if let last = panels.last, rect.minY - last.maxY < 2 {
                panels[panels.count - 1] = last.union(rect)
            } else {
                panels.append(rect)
            }
        }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        for panel in panels {
            NSBezierPath(roundedRect: panel.insetBy(dx: 0, dy: -5), xRadius: 8, yRadius: 8).fill()
        }

        storage.enumerateAttribute(.markdownImage, in: characters) { value, run, _ in
            guard let target = value as? String, let image = imageProvider?(target) else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let line = lineFragmentUsedRect(forGlyphAt: max(NSMaxRange(glyphs) - 1, glyphs.location), effectiveRange: nil)
            let size = MarkdownTheme.displaySize(of: image, width: container.size.width)
            let frame = NSRect(x: 0, y: line.maxY + 6, width: size.width, height: size.height)
            imageFrames.removeAll { $0.target == target }
            imageFrames.append((frame, target))

            let onScreen = frame.offsetBy(dx: origin.x, dy: origin.y)
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(roundedRect: onScreen, xRadius: 8, yRadius: 8)
            clip.addClip()
            image.draw(in: onScreen, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(0.1).setStroke()
            let edge = NSBezierPath(roundedRect: onScreen.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            edge.lineWidth = 1
            edge.stroke()
        }

        storage.enumerateAttribute(.markdownQuote, in: characters) { value, run, _ in
            guard value != nil else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
            let bar = NSRect(x: origin.x, y: rect.minY + origin.y + 2, width: 3, height: rect.height - 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.markdownBullet, in: characters) { value, run, _ in
            guard value != nil else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            let font = storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont ?? MarkdownTheme.bodyFont
            let size = font.pointSize * 0.36
            let dot = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2 + 1, width: size, height: size)
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        storage.enumerateAttribute(.markdownCheckbox, in: characters) { value, run, _ in
            guard let checked = value as? Bool else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            Self.drawCheckbox(checked: checked, in: rect)
        }
    }

    /// The Notes checkbox: a ring, or a filled disc with a tick.
    static func drawCheckbox(checked: Bool, in rect: NSRect) {
        let size: CGFloat = 17
        let box = NSRect(x: rect.minX, y: rect.midY - size / 2 + 1, width: size, height: size)
        if checked {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: box).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 4.8, y: box.midY + 0.2))
            tick.line(to: NSPoint(x: box.minX + 7.4, y: box.midY + 2.8))
            tick.line(to: NSPoint(x: box.maxX - 4.4, y: box.midY - 2.8))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            ring.stroke()
        }
    }
}

// MARK: - Text view

final class MarkdownNSTextView: NSTextView {
    var placeholder: String = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onExitTop: (() -> Void)?
    var onInsertImage: ((Data, String?) -> String?)?
    var onOpenImage: ((String) -> Void)?
    /// An image's height depends on the column width, so a resize restyles.
    var onWidthChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        textContainer?.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        if widthChanged, textStorage?.string.contains("![") == true { onWidthChange?() }
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: layout.usedRect(for: container).height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        var attributes = MarkdownTheme.body
        attributes[.foregroundColor] = NSColor.placeholderTextColor
        (placeholder as NSString).draw(
            with: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y,
                         width: bounds.width, height: bounds.height),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: Clicking a checkbox

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let target = imageTarget(at: point) {
            onOpenImage?(target)
            return
        }
        if let index = checkboxIndex(at: point) {
            toggleCheckbox(atCharacter: index)
            return
        }
        super.mouseDown(with: event)
    }

    private func checkboxIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var run = NSRange()
        guard storage.attribute(.markdownCheckbox, at: index, effectiveRange: &run) != nil else { return nil }
        // Only the drawn disc, not the whole width of the hidden `- [ ]`.
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: run, actualCharacterRange: nil),
                                       in: container)
        guard inContainer.x <= rect.minX + 22 else { return nil }
        return index
    }

    private func toggleCheckbox(atCharacter index: Int) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: lineRange)
        let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
        guard let toggled = MarkdownStyler.togglingCheckbox(body) else { return }
        replace(NSRange(location: lineRange.location, length: (body as NSString).length), with: toggled, select: nil)
    }

    private func imageTarget(at point: NSPoint) -> String? {
        guard let layout = layoutManager as? MarkdownLayoutManager else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layout.imageFrames.first { $0.rect.contains(inContainer) }?.target
    }

    // MARK: Images

    /// A pasted screenshot or image becomes an attachment and a reference on
    /// a line of its own. Text on the pasteboard wins: copying cells from a
    /// spreadsheet also carries a picture of them, and those should paste as
    /// text.
    override func paste(_ sender: Any?) {
        if insertImages(from: .general, replacing: selectedRange()) { return }
        super.paste(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        if insertImages(from: sender.draggingPasteboard, replacing: NSRange(location: index, length: 0)) {
            return true
        }
        return super.performDragOperation(sender)
    }

    func insertImages(from pasteboard: NSPasteboard, replacing range: NSRange) -> Bool {
        guard let onInsertImage else { return false }
        let payloads = imagePayloads(on: pasteboard)
        let references = payloads.compactMap { onInsertImage($0.data, $0.name) }
        guard !references.isEmpty else { return false }

        let ns = string as NSString
        let newline = unichar(10)
        let before = range.location > 0 && ns.character(at: range.location - 1) != newline ? "\n" : ""
        let after = NSMaxRange(range) < ns.length && ns.character(at: NSMaxRange(range)) != newline ? "\n" : ""
        let text = before + references.joined(separator: "\n") + "\n" + after
        let caret = range.location + (text as NSString).length - (after as NSString).length
        replace(range, with: text, select: NSRange(location: caret, length: 0))
        window?.makeFirstResponder(self)
        return true
    }

    private func imagePayloads(on pasteboard: NSPasteboard) -> [(data: Data, name: String?)] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            let files = images.compactMap { url in (try? Data(contentsOf: url)).map { (data: $0, name: Optional(url.lastPathComponent)) } }
            if !files.isEmpty { return files }
            if !urls.isEmpty { return [] }
        }
        if pasteboard.string(forType: .string) != nil { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [(data, nil)] }
        }
        return []
    }

    // MARK: Lists

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: caret.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        switch MarkdownStyler.continuation(of: line) {
        case .insert(let text)?:
            insertText(text, replacementRange: caret)
        case .end(let markerLength)?:
            // Return on an empty item ends the list: the marker goes, the line stays.
            replace(NSRange(location: lineRange.location, length: markerLength), with: "",
                    select: NSRange(location: lineRange.location, length: 0))
        case nil:
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        guard currentLineIsListItem else { return super.insertTab(sender) }
        transformLines { "  " + $0 }
    }

    override func insertBacktab(_ sender: Any?) {
        guard currentLineIsListItem else { return super.insertBacktab(sender) }
        transformLines { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
    }

    private var currentLineIsListItem: Bool {
        let ns = string as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        return MarkdownStyler.continuation(of: line.trimmingCharacters(in: .newlines)) != nil
    }

    /// ↑ on the first visual line goes back up to the title, as in Notes.
    override func moveUp(_ sender: Any?) {
        guard let onExitTop, isOnFirstLine else { return super.moveUp(sender) }
        onExitTop()
    }

    private var isOnFirstLine: Bool {
        let ns = string as NSString
        guard ns.length > 0, let layout = layoutManager, layout.numberOfGlyphs > 0 else { return true }
        let location = selectedRange().location
        // At the very end after a newline, the caret sits on a line of its own.
        if location >= ns.length { return ns.hasSuffix("\n") ? false : layout.lineFragmentRect(
            forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil).minY <= 0.5 }
        let glyph = layout.glyphIndexForCharacter(at: location)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY <= 0.5
    }

    // MARK: Formatting

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "b"): toggleWrap("**")
        case ([.command], "i"): toggleWrap("*")
        case ([.command], "k"): insertLink()
        case ([.command, .shift], "x"): toggleWrap("~~")
        case ([.command, .shift], "l"): transformLines(MarkdownStyler.togglingChecklist)
        case ([.command, .option], "c"): insertCodeBlock()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Wraps the selection in `fence`, or unwraps it if it is wrapped already.
    /// With nothing selected, leaves the caret between a fresh pair.
    func toggleWrap(_ fence: String) {
        let ns = string as NSString
        let selection = selectedRange()
        let length = (fence as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == fence, ns.substring(with: after) == fence {
            let inner = ns.substring(with: selection)
            replace(NSRange(location: before.location, length: NSMaxRange(after) - before.location), with: inner,
                    select: NSRange(location: before.location, length: selection.length))
            return
        }
        let inner = ns.substring(with: selection)
        replace(selection, with: fence + inner + fence,
                select: NSRange(location: selection.location + length, length: selection.length))
    }

    /// Rewrites every line the selection touches.
    func transformLines(_ transform: (String) -> String) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        var text = ns.substring(with: lines)
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { text.removeLast() }
        let rewritten = text.components(separatedBy: "\n").map(transform).joined(separator: "\n")
        let length = (rewritten as NSString).length
        replace(NSRange(location: lines.location, length: (text as NSString).length), with: rewritten,
                select: NSRange(location: lines.location + length, length: 0))
    }

    func insertCodeBlock() {
        let selection = selectedRange()
        let inner = (string as NSString).substring(with: selection)
        let block = "```\n" + inner + "\n```"
        replace(selection, with: block, select: NSRange(location: selection.location + 4, length: (inner as NSString).length))
    }

    func insertLink() {
        let selection = selectedRange()
        let inner = (string as NSString).substring(with: selection)
        let text = inner.isEmpty ? "link" : inner
        let link = "[\(text)](https://)"
        // Select the URL, ready to paste over.
        let urlStart = selection.location + (text as NSString).length + 3
        replace(selection, with: link, select: NSRange(location: urlStart, length: 8))
    }

    /// Every edit goes through `shouldChangeText`/`didChangeText`, so it is one
    /// undoable step and the binding hears about it.
    private func replace(_ range: NSRange, with text: String, select: NSRange?) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }
}
