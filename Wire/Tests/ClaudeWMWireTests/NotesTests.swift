import Foundation
import Testing
@testable import ClaudeWMWire

/// The note format both ends write: how each run is styled while typing,
/// how lists carry on, and how image references are read and rewritten.
@Suite("Notes")
struct NotesTests {

    private func styled(_ text: String, _ style: MarkdownStyle) -> [String] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).filter { $0.style == style }.map { ns.substring(with: $0.range) }
    }

    @Test func theNoteFormat() {
        #expect(styled("## What done looks like", .heading(2)) == ["## What done looks like"], "h2 line")
        #expect(styled("## What done looks like", .marker) == ["## "], "h2 marker")
        #expect(styled("#57 is linked", .heading(1)).isEmpty, "#hashtag is not a heading")
        #expect(styled("Delete is **destructive** now", .bold) == ["**destructive**"], "bold")
        #expect(styled("Delete is **destructive** now", .marker) == ["**", "**"], "bold markers")
        #expect(styled("an *aside* here", .italic) == ["*aside*"], "italic star")
        #expect(styled("call product_delete_dialog now", .italic).isEmpty, "snake_case is not italic")
        #expect(styled("an _aside_ here", .italic) == ["_aside_"], "italic underscore")
        #expect(styled("**strong**", .italic).isEmpty, "bold is not also italic")
        #expect(styled("~~gone~~ now", .strikethrough) == ["~~gone~~"], "strike")
        #expect(styled("use `window.confirm()` here", .inlineCode) == ["`window.confirm()`"], "inline code")
        #expect(styled("`**not bold**`", .bold).isEmpty, "no bold inside code")
        #expect(styled("see [the PR](https://x.y/a_b_c) now", .link) == ["the PR"], "link text")
        #expect(styled("see [x](https://a.b/_c_)", .italic).isEmpty, "no italic in url")
        #expect(styled("- first item", .bullet) == ["-"], "bullet")
        #expect(MarkdownStyler.spans(in: "- first").contains { $0.style == .listItem(depth: 0, marker: 2) }, "bullet list item")
        #expect(MarkdownStyler.spans(in: "    - deep").contains { $0.style == .listItem(depth: 2, marker: 2) }, "nested bullet depth")
        #expect(styled("- [ ] write tests", .checkbox(checked: false)) == ["- [ ]"], "checkbox open")
        #expect(styled("- [x] wrote tests", .checkbox(checked: true)) == ["- [x]"], "checkbox done")
        #expect(styled("- [x] wrote tests", .checkedText) == ["wrote tests"], "checked text")
        #expect(styled("- [ ] a", .bullet).isEmpty, "checklist is not a bullet")
        #expect(styled("> keep it", .quote) == ["> keep it"], "quote")
        let fenced = "intro\n```tsx\nconst a = **b**\n```\nafter **bold**"
        #expect(styled(fenced, .codeBlock) == ["```tsx", "const a = **b**", "```"], "code block lines")
        #expect(styled(fenced, .bold) == ["**bold**"], "nothing bold inside fence")
        #expect(styled("---", .marker) == ["---"], "rule")
        #expect(styled("# A **big** deal", .bold) == ["**big**"], "bold inside heading")
        #expect(styled("🚀 **go**", .bold) == ["**go**"], "utf16 ranges with emoji")
        typealias C = MarkdownStyler.Continuation
        #expect(MarkdownStyler.continuation(of: "- milk") == C.insert("\n- "), "continue bullet")
        #expect(MarkdownStyler.continuation(of: "  * eggs") == C.insert("\n  * "), "continue nested bullet")
        #expect(MarkdownStyler.continuation(of: "- [x] done") == C.insert("\n- [ ] "), "continue checklist unchecked")
        #expect(MarkdownStyler.continuation(of: "9. nine") == C.insert("\n10. "), "continue ordered")
        #expect(MarkdownStyler.continuation(of: "- ") == C.end(markerLength: 2), "end empty bullet")
        #expect(MarkdownStyler.continuation(of: "- [ ] ") == C.end(markerLength: 6), "end empty checklist")
        #expect(MarkdownStyler.continuation(of: "hello") == nil, "plain line no continuation")
        #expect(MarkdownStyler.togglingChecklist("buy milk") == "- [ ] buy milk", "toggle checklist on")
        #expect(MarkdownStyler.togglingChecklist("  - buy milk") == "  - [ ] buy milk", "toggle checklist from bullet")
        #expect(MarkdownStyler.togglingChecklist("- [x] buy milk") == "buy milk", "toggle checklist off")
        #expect(MarkdownStyler.togglingCheckbox("- [ ] a") == "- [x] a", "tick box")
        #expect(MarkdownStyler.togglingCheckbox("- [X] a") == "- [ ] a", "untick box")
        #expect(MarkdownStyler.togglingCheckbox("- a") == nil, "no box")
        #expect(MarkdownStyler.settingHeading("Title", level: 2) == "## Title", "heading set")
        #expect(MarkdownStyler.settingHeading("### Title", level: 1) == "# Title", "heading change")
        #expect(MarkdownStyler.settingHeading("## Title", level: 0) == "Title", "heading clear")
        #expect(MarkdownStyler.spans(in: "![shot](attachment:ABC)").contains { $0.style == .image(target: "attachment:ABC") }, "image line")
        #expect(styled("![shot](attachment:ABC)", .marker) == ["![shot](attachment:ABC)"], "image line is dimmed")
        #expect(!MarkdownStyler.spans(in: "see ![a](b) here").contains { if case .image = $0.style { return true }; return false }, "inline image is not a block")
        let id = UUID()
        let ref = AttachmentReferences.markdown(alt: "Screen Shot 2026", id: id)
        #expect(ref == "![Screen Shot 2026](attachment:\(id.uuidString))", "reference shape")
        #expect(AttachmentReferences.ids(in: "a\n\(ref)\nb \(ref)") == [id], "ids found once")
        #expect(AttachmentReferences.ids(in: "![x](https://a.b/c.png)").isEmpty, "ids ignore other links")
        #expect(AttachmentReferences.ids(in: "![x](attachment:\(id.uuidString.lowercased()))") == [id], "lowercase uuid still read")
        #expect(AttachmentReferences.replacing(in: "before \(ref) after") { "[\($0)]" } == "before [Screen Shot 2026] after", "replace for export")
        let other = UUID()
        #expect(AttachmentReferences.repointing(ref, [id: other]) == AttachmentReferences.markdown(alt: "Screen Shot 2026", id: other), "repoint")
        #expect(AttachmentReferences.markdown(alt: "a]b", id: id).hasPrefix("![ab]"), "alt brackets stripped")
    }
}
