//
//  NotesEditor.swift
//  ClaudeWMMobile
//
//  A card's notes, edited the way the Mac's card window edits them: Markdown
//  styled in place, never converted. The styling rules are the Mac's own —
//  `MarkdownStyler` lives in `ClaudeWMWire` so both apps draw `## ` the same
//  size and fade the same markers — and the text stays Markdown, because Claude,
//  `gh` and the Mac all read it.
//
//  A picture is drawn the way the Mac draws it: under its reference line, in
//  space that line's paragraph spacing reserves, by the layout manager
//  (`NotesLayoutManager`). The reference stays in the text, small and faded,
//  so deleting the line is how a picture is removed — on both. A photo still
//  on its way to the Mac carries its progress across its foot.
//
//  UIKit rather than `TextEditor` because three things need the text view
//  itself: restyling without moving the caret, Return carrying a list on, and
//  ⌘V (or Paste) accepting a picture.
//

import SwiftUI
import UIKit
import ClaudeWMWire

/// What the formatting bar and the screen around the editor ask of it.
@MainActor
final class NotesEditorController {
    fileprivate weak var textView: NotesTextView?

    /// Set by the screen: the bar's photo buttons, and a picture pasted in.
    var onPhotoLibrary: (() -> Void)?
    var onCamera: (() -> Void)?
    var onPasteImage: ((UIImage) -> Void)?

    func focus() { textView?.becomeFirstResponder() }

    /// Puts an image's line in at the caret, on a line of its own.
    func insertImageLine(_ markdown: String) {
        guard let textView else { return }
        let ns = textView.text as NSString
        let caret = textView.selectedRange.location
        let atLineStart = caret == 0 || ns.character(at: caret - 1) == 10
        let atLineEnd = caret >= ns.length || ns.character(at: caret) == 10
        let insertion = (atLineStart ? "" : "\n") + markdown + (atLineEnd ? "\n" : "\n")
        textView.replace(NSRange(location: caret, length: 0), with: insertion)
    }

    func toggleChecklist() {
        editLine { MarkdownStyler.togglingChecklist($0) }
    }

    func setHeading(_ level: Int) {
        editLine { MarkdownStyler.settingHeading($0, level: level) }
    }

    /// Wraps the selection, or puts the markers in to type between.
    func wrap(_ marker: String) {
        guard let textView else { return }
        let range = textView.selectedRange
        let selected = (textView.text as NSString).substring(with: range)
        textView.replace(range, with: marker + selected + marker)
        if range.length == 0 {
            textView.selectedRange = NSRange(location: range.location + marker.count, length: 0)
        }
    }

    func insertCodeBlock() {
        guard let textView else { return }
        let range = textView.selectedRange
        let selected = (textView.text as NSString).substring(with: range)
        textView.replace(range, with: "```\n" + selected + "\n```")
        textView.selectedRange = NSRange(location: range.location + 4 + (selected as NSString).length, length: 0)
    }

    private func editLine(_ change: (String) -> String) {
        guard let textView else { return }
        let ns = textView.text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        var line = ns.substring(with: lineRange)
        let newline = line.hasSuffix("\n")
        if newline { line.removeLast() }
        let changed = change(line)
        let caretOffset = textView.selectedRange.location - lineRange.location
        textView.replace(lineRange, with: changed + (newline ? "\n" : ""))
        let delta = (changed as NSString).length - (line as NSString).length
        textView.selectedRange = NSRange(
            location: lineRange.location + max(0, min((changed as NSString).length, caretOffset + delta)), length: 0
        )
    }
}

/// Where the editor gets its pictures. `revision` changes whenever any answer
/// might — the closures read state SwiftUI cannot see through UIKit, so this is
/// how the editor knows to lay out again.
struct NotesImageSource {
    enum Upload: Equatable {
        case sending(Double)
        case failed
    }

    var image: (String) -> UIImage?
    var upload: (String) -> Upload?
    var retry: (String) -> Void
    var revision: Int

    static let none = NotesImageSource(image: { _ in nil }, upload: { _ in nil }, retry: { _ in }, revision: 0)
}

struct NotesEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    let controller: NotesEditorController
    var images: NotesImageSource = .none

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NotesTextView {
        let view = NotesTextView.make()
        view.images = images
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = NotesStyle.body
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.placeholder.text = placeholder
        view.text = text
        view.restyle()
        view.inputAccessoryView = NotesFormatBar(controller: controller)
        view.onPasteImage = { [weak controller] in controller?.onPasteImage?($0) }
        controller.textView = view
        return view
    }

    func updateUIView(_ view: NotesTextView, context: Context) {
        context.coordinator.parent = self
        let picturesChanged = view.images.revision != images.revision
        view.images = images
        if view.text != text || picturesChanged {
            if view.text != text { view.text = text }
            view.restyle()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NotesEditor

        init(_ parent: NotesEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? NotesTextView)?.restyle()
            parent.text = textView.text
        }

        /// Return on a list item carries the list on; on an empty one it ends
        /// it — as in Notes, and as in the Mac's card window.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            guard string == "\n", range.length == 0, let view = textView as? NotesTextView else { return true }
            let ns = textView.text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            switch MarkdownStyler.continuation(of: line) {
            case .insert(let next):
                view.replace(range, with: next)
                return false
            case .end(let markerLength):
                view.replace(NSRange(location: lineStart, length: markerLength), with: "")
                return false
            case nil:
                return true
            }
        }
    }
}

/// The text view, with a placeholder, a paste that takes pictures, and the
/// pictures drawn in the text.
final class NotesTextView: UITextView {
    let placeholder = UILabel()
    var onPasteImage: ((UIImage) -> Void)?
    var images: NotesImageSource = .none {
        didSet { notesLayout?.images = images }
    }
    private var laidOutWidth: CGFloat = 0
    private var imageTap: UITapGestureRecognizer?

    private var notesLayout: NotesLayoutManager? { layoutManager as? NotesLayoutManager }

    /// TextKit 1, built by hand: a text view given a container that already
    /// has a layout manager uses that one, and `NSLayoutManager` is where
    /// drawing under a line fragment is possible at all — the Mac's reason
    /// too.
    static func make() -> NotesTextView {
        let storage = NSTextStorage()
        let layout = NotesLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return NotesTextView(frame: .zero, textContainer: container)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = NotesStyle.body
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        addSubview(placeholder)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedImage(_:)))
        addGestureRecognizer(tap)
        imageTap = tap
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - textContainerInset.left - textContainerInset.right
        let size = placeholder.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top, width: width, height: size.height)
        // A picture's height follows the column's width.
        if abs(width - laidOutWidth) > 0.5 {
            laidOutWidth = width
            if text.contains("![") { restyle() }
        }
    }

    // MARK: Tapping a picture

    /// A photo that did not reach the Mac is sent again by tapping it. Other
    /// taps are the text view's, so the caret still goes where you touch.
    @objc private func tappedImage(_ gesture: UITapGestureRecognizer) {
        guard let target = imageTarget(at: gesture.location(in: self)) else { return }
        images.retry(target)
    }

    private func imageTarget(at point: CGPoint) -> String? {
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        return notesLayout?.imageFrames.first { $0.rect.contains(inContainer) }?.target
    }

    /// Only on a photo that failed: anywhere else the tap is the text view's.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === imageTap else { return super.gestureRecognizerShouldBegin(gesture) }
        guard let target = imageTarget(at: gesture.location(in: self)) else { return false }
        return images.upload(target) == .failed
    }

    /// Replaces text as typing would — undoable, and through the delegate's
    /// change callback so the binding follows.
    func replace(_ range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
    }

    // MARK: Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Text on the pasteboard beats a picture of it — a copied spreadsheet
    /// carries both, and the Mac makes the same choice.
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if !board.hasStrings, board.hasImages, let image = board.image {
            onPasteImage?(image)
        } else {
            super.paste(sender)
        }
    }

    // MARK: Styling

    func restyle() {
        placeholder.isHidden = !text.isEmpty
        let storage = textStorage
        let whole = NSRange(location: 0, length: storage.length)
        let selection = selectedRange
        storage.beginEditing()
        storage.setAttributes(NotesStyle.base, range: whole)
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right
                           - textContainer.lineFragmentPadding * 2)
        for span in MarkdownStyler.spans(in: text) where NSMaxRange(span.range) <= storage.length {
            NotesStyle.apply(span, to: storage)
            if case .image(let target) = span.style {
                NotesStyle.applyImage(target, image: images.image(target), width: width,
                                      range: span.range, to: storage)
            }
        }
        storage.endEditing()
        selectedRange = selection
        typingAttributes = NotesStyle.base
    }
}

enum NotesStyle {
    static let body = UIFont.preferredFont(forTextStyle: .body)

    static var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: UIColor.label]
    }

    static func apply(_ span: MarkdownSpan, to storage: NSTextStorage) {
        let range = span.range
        switch span.style {
        case .heading(let level):
            let size: CGFloat = [28, 22, 19][min(max(level, 1), 3) - 1]
            storage.addAttribute(.font, value: UIFont.systemFont(ofSize: level > 3 ? 17 : size,
                                                                 weight: level == 1 ? .bold : .semibold), range: range)
        case .marker:
            storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range)
        case .bold:
            addTrait(.traitBold, to: storage, in: range)
        case .italic:
            addTrait(.traitItalic, to: storage, in: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode:
            storage.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .backgroundColor: UIColor.tertiarySystemFill,
            ], range: range)
        case .codeBlock:
            storage.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .backgroundColor: UIColor.secondarySystemBackground,
            ], range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        case .bullet:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .checkbox:
            storage.addAttributes([
                .foregroundColor: UIColor.tintColor,
                .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
            ], range: range)
        case .checkedText:
            storage.addAttributes([
                .foregroundColor: UIColor.secondaryLabel,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .image:
            storage.addAttributes([
                .foregroundColor: UIColor.tertiaryLabel,
                .font: UIFont.systemFont(ofSize: 11),
            ], range: range)
        case .listItem(let depth, _):
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = CGFloat(depth) * 20 + 18
            paragraph.firstLineHeadIndent = CGFloat(depth) * 20
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }

    /// An image line: its reference, small and faded, with room below for the
    /// picture, which `NotesLayoutManager` draws there — `MarkdownTheme
    /// .applyImage` on the Mac, with the same sizing.
    static func applyImage(_ target: String, image: UIImage?, width: CGFloat, range: NSRange, to storage: NSTextStorage) {
        guard let image, image.size.width > 0, image.size.height > 0, width > 0 else { return }
        let size = displaySize(of: image, width: width)
        storage.addAttribute(.notesImage, value: target, range: range)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = size.height + 12
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// At most its own size in points — a Retina screenshot is half its pixel
    /// width — never wider than the column, never taller than 420.
    static func displaySize(of image: UIImage, width: CGFloat) -> CGSize {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let natural = CGSize(width: pixels.width / 2, height: pixels.height / 2)
        var size = natural
        if size.width > width { size = CGSize(width: width, height: width * natural.height / natural.width) }
        if size.height > 420 { size = CGSize(width: 420 * natural.width / natural.height, height: 420) }
        return CGSize(width: floor(size.width), height: floor(size.height))
    }

    private static func addTrait(_ trait: UIFontDescriptor.SymbolicTraits, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = (value as? UIFont) ?? body
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: run)
            }
        }
    }
}

extension NSAttributedString.Key {
    static let notesImage = NSAttributedString.Key("pitwall.notesImage")
}

/// Draws each picture under its reference line, in the space that line's
/// paragraph spacing reserved, with an upload's progress across its foot.
final class NotesLayoutManager: NSLayoutManager {
    var images: NotesImageSource = .none
    /// Where each picture was last drawn, in container coordinates, so a tap
    /// can find it.
    private(set) var imageFrames: [(rect: CGRect, target: String)] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(.notesImage, in: characters) { value, run, _ in
            guard let target = value as? String, let image = images.image(target) else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let line = lineFragmentUsedRect(forGlyphAt: max(NSMaxRange(glyphs) - 1, glyphs.location), effectiveRange: nil)
            let size = NotesStyle.displaySize(of: image, width: width)
            let frame = CGRect(x: container.lineFragmentPadding, y: line.maxY + 6, width: size.width, height: size.height)
            imageFrames.removeAll { $0.target == target }
            imageFrames.append((frame, target))

            let onScreen = frame.offsetBy(dx: origin.x, dy: origin.y)
            let shape = UIBezierPath(roundedRect: onScreen, cornerRadius: 8)
            UIGraphicsGetCurrentContext()?.saveGState()
            shape.addClip()
            image.draw(in: onScreen)

            switch images.upload(target) {
            case .sending(let fraction):
                // Faded until it has arrived, with a bar along the foot.
                UIColor.systemBackground.withAlphaComponent(0.35).setFill()
                shape.fill()
                let track = CGRect(x: onScreen.minX + 10, y: onScreen.maxY - 14, width: onScreen.width - 20, height: 4)
                UIColor.black.withAlphaComponent(0.35).setFill()
                UIBezierPath(roundedRect: track, cornerRadius: 2).fill()
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY,
                                                 width: track.width * min(1, max(0.02, fraction)), height: track.height),
                             cornerRadius: 2).fill()
            case .failed:
                UIColor.black.withAlphaComponent(0.45).setFill()
                shape.fill()
                let label = "Not sent — tap to try again" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.white,
                ]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: onScreen.midX - textSize.width / 2, y: onScreen.midY - textSize.height / 2),
                           withAttributes: attributes)
            case nil:
                break
            }
            UIGraphicsGetCurrentContext()?.restoreGState()
            UIColor.label.withAlphaComponent(0.1).setStroke()
            let edge = UIBezierPath(roundedRect: onScreen.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}

/// The bar above the keyboard: text styles, checklist, code, photos, heading,
/// and a way to put the keyboard away.
private final class NotesFormatBar: UIInputView {
    init(controller: NotesEditorController) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        func button(_ symbol: String, _ label: String, menu: UIMenu? = nil, action: (() -> Void)? = nil) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol,
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
            configuration.baseForegroundColor = .label
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = label
            if let menu {
                button.menu = menu
                button.showsMenuAsPrimaryAction = true
            } else if let action {
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            }
            return button
        }

        weak let controller = controller
        let styles = UIMenu(children: [
            UIAction(title: "Title") { _ in controller?.setHeading(1) },
            UIAction(title: "Heading") { _ in controller?.setHeading(2) },
            UIAction(title: "Subheading") { _ in controller?.setHeading(3) },
            UIAction(title: "Body") { _ in controller?.setHeading(0) },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Bold", image: UIImage(systemName: "bold")) { _ in controller?.wrap("**") },
                UIAction(title: "Italic", image: UIImage(systemName: "italic")) { _ in controller?.wrap("*") },
                UIAction(title: "Strikethrough", image: UIImage(systemName: "strikethrough")) { _ in controller?.wrap("~~") },
            ]),
        ])
        let code = UIMenu(children: [
            UIAction(title: "Inline Code", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
                controller?.wrap("`")
            },
            UIAction(title: "Code Block", image: UIImage(systemName: "text.alignleft")) { _ in
                controller?.insertCodeBlock()
            },
        ])
        let photo = UIMenu(children: [
            UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) { _ in
                controller?.onPhotoLibrary?()
            },
            UIAction(title: "Take Photo", image: UIImage(systemName: "camera")) { _ in controller?.onCamera?() },
            UIAction(title: "Paste Image", image: UIImage(systemName: "doc.on.clipboard"),
                    ) { _ in
                if let image = UIPasteboard.general.image { controller?.onPasteImage?(image) }
            },
        ])

        let leading = UIStackView(arrangedSubviews: [
            button("textformat", "Text Style", menu: styles),
            button("checklist", "Checklist") { controller?.toggleChecklist() },
            button("chevron.left.forwardslash.chevron.right", "Code", menu: code),
            button("photo", "Add Photo", menu: photo),
            button("camera", "Take Photo") { controller?.onCamera?() },
            button("number", "Heading") { controller?.setHeading(2) },
        ])
        leading.distribution = .equalSpacing
        let dismiss = button("keyboard.chevron.compact.down", "Hide Keyboard") {
            controller?.textView?.resignFirstResponder()
        }
        let row = UIStackView(arrangedSubviews: [leading, dismiss])
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }
}
