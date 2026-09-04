// Repaints a real Claude WM screenshot with demo content.
//
// The window chrome, toolbar, column headers and all the app's own geometry are
// left exactly as captured; only the regions carrying private text — the
// sidebar list, the project title, and the cards inside each column — are
// filled back in and redrawn. Every colour and measurement below was read off
// the screenshot itself, so the result is the real UI with different words in
// it rather than a mock-up of one.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

let src = CGImageSourceCreateWithURL(inURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let W = image.width, H = image.height

let ctx = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8,
    bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// The capture goes down first, in the context's own bottom-left orientation, so
// it lands upright — flipping first would draw it on its head. Only then is the
// context flipped, so every number below reads the way it was measured. For a
// CGBitmapContext the first row in memory is the top row, so under that flip a
// top-down y is also the buffer's row index, which is what the sampler relies on.
ctx.interpolationQuality = .high
ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1)

let buffer = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)

func pixel(_ x: Int, _ y: Int) -> CGColor {
    let o = (y * W + x) * 4
    return CGColor(
        srgbRed: CGFloat(buffer[o]) / 255,
        green: CGFloat(buffer[o + 1]) / 255,
        blue: CGFloat(buffer[o + 2]) / 255,
        alpha: 1
    )
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Text

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

func line(_ s: String, _ f: CTFont, _ color: CGColor, tracking: CGFloat = 0) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(
        string: s,
        attributes: [.font: f, .foregroundColor: color, .kern: tracking]
    ))
}

func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Draws a laid-out line with its baseline at `baseline`, undoing the context
/// flip so the glyphs are not drawn upside down.
func draw(_ l: CTLine, x: CGFloat, baseline: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: x, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(l, ctx)
    ctx.restoreGState()
}

func draw(_ s: String, x: CGFloat, baseline: CGFloat, _ f: CTFont, _ color: CGColor,
          tracking: CGFloat = 0) {
    draw(line(s, f, color, tracking: tracking), x: x, baseline: baseline)
}

/// Wraps `s` to `maxWidth`, the way the card body does.
func wrap(_ s: String, _ f: CTFont, _ color: CGColor, maxWidth: CGFloat) -> [CTLine] {
    let attributed = NSAttributedString(
        string: s, attributes: [.font: f, .foregroundColor: color]
    )
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    var lines: [CTLine] = []
    var start = 0
    let n = attributed.length
    while start < n {
        let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
        guard count > 0 else { break }
        lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
        start += count
    }
    return lines
}

// MARK: - Measured geometry
//
// All of these came off the capture: the column ground and card fill differ by
// 14 levels of grey, which is why the cards read as cards at all.

let columnGround = rgb(234, 233, 233)
let cardFill     = rgb(248, 248, 248)
let cardText     = rgb(60, 60, 62)
let doneText     = rgb(150, 150, 152)
let mutedText    = rgb(138, 138, 143)
let groupText    = rgb(130, 130, 136)

let columnLefts: [CGFloat] = [642, 1274, 1906, 2538, 3170]
let columnWidth: CGFloat = 599
let cardInset: CGFloat = 22          // card edge inside the column
let cardPadding: CGFloat = 18        // text inset inside the card
let cardRadius: CGFloat = 14
let lineHeight: CGFloat = 30
let cardGap: CGFloat = 27
let firstBaseline: CGFloat = 42      // from the card's top edge

let cardsTop: CGFloat = 272
let cardsBottom: CGFloat = 1890

let cardFont = font(28)

// MARK: - Columns

struct Column {
    let titles: [String]
    let done: Bool
}

let columns: [Column] = [
    // Backlog
    Column(titles: [
        "Dark mode for the settings pane",
        "Cache avatar images between launches",
        "Keyboard shortcut to jump between columns",
        "Export a board as CSV",
        "Empty state for a board with no cards yet",
        "Retry failed uploads with a backoff",
        "Search should match card notes, not just titles",
        "Collapse a column that has gone long",
        "Per-project accent colour",
        "Remember scroll position when switching views",
        "Bulk-move selected cards",
        "Archive instead of delete",
        "Quick look for an image in the file browser",
        "Remember which commands were opted in",
        "Show a card's subtask progress on the board",
        "Filter by owner from the keyboard",
    ], done: false),
    // To Do
    Column(titles: [
        "Rename a column inline",
        "Remember the last view per project",
        "Undo should cover card deletion",
    ], done: false),
    // In Progress
    Column(titles: [
        "Drag a card between columns without the flicker",
        "Persist terminal scrollback across restarts",
        "Fix the cursor jump when renaming a card",
        "Warn before unlinking a repository",
        "Show the diffstat on a card with a branch",
        "Keep the pty size when the window resizes",
    ], done: false),
    // Review
    Column(titles: [
        "Link a card to an existing GitHub issue",
        "Show the branch and PR on the card badge",
        "Debounce the issue refresh loop",
        "Handle a default branch that is not main",
        "Tolerate a malformed tasks.json",
        "Refuse a label the repository does not have",
        "Propose issue links instead of joining on title",
        "Grey the badge when an issue closes",
        "Re-read the gate on every message",
        "Trim the output tail at a newline",
        "Un-assign an issue when a dispatch fails",
        "Rebase onto the default branch before the PR",
        "Reconcile runs left over from a sleep",
        "Leave a worktree in place after a failure",
    ], done: false),
    // Done
    Column(titles: [
        "Ship the read-only file browser",
        "Syntax highlighting for Swift and TypeScript",
        "Bracketed paste in the terminal",
        "Cache open issues so the board paints instantly",
        "Pair the phone client over TLS-PSK",
        "Field ownership instead of last-writer-wins",
        "Back-fill column roles on old boards",
        "Stagger Run All so workers win their races",
        "Notify only on moves somebody else made",
        "Drain both pipes when spawning gh",
        "Watch the directory, not the file descriptor",
        "Refuse a path that escapes the repository",
        "Resolve gh by absolute path, not by name",
        "Give the child a controlling terminal",
        "Raise the scrollback to five thousand lines",
        "Suppress echoes by content hash",
    ], done: true),
]

for (index, column) in columns.enumerated() {
    let left = columnLefts[index]
    let region = CGRect(x: left + 2, y: cardsTop,
                        width: columnWidth - 4, height: cardsBottom - cardsTop)

    ctx.saveGState()
    ctx.clip(to: region)
    ctx.setFillColor(columnGround)
    ctx.fill(region)

    let cardX = left + cardInset
    let cardWidth = columnWidth - cardInset * 2
    let textWidth = cardWidth - cardPadding * 2
    var y = cardsTop + 8

    for title in column.titles {
        let colour = column.done ? doneText : cardText
        let lines = wrap(title, cardFont, colour, maxWidth: textWidth)
        let height = (firstBaseline * 2 - lineHeight) + CGFloat(lines.count) * lineHeight
        let card = CGRect(x: cardX, y: y, width: cardWidth, height: height)

        ctx.setFillColor(cardFill)
        ctx.addPath(rounded(card, cardRadius))
        ctx.fillPath()

        for (row, l) in lines.enumerated() {
            let baseline = y + firstBaseline + CGFloat(row) * lineHeight
            draw(l, x: cardX + cardPadding, baseline: baseline)

            // A completed card is struck through, which is the one thing that
            // makes the Done column readable at a glance.
            if column.done {
                ctx.setFillColor(doneText)
                ctx.fill(CGRect(x: cardX + cardPadding, y: baseline - 9,
                                width: width(l), height: 2))
            }
        }

        y += height + cardGap
        if y > cardsBottom { break }
    }

    ctx.restoreGState()
}

// MARK: - Sidebar
//
// The sidebar carries a faint vertical wash, so instead of guessing a flat
// colour each scanline is refilled with the colour the capture already has at
// x = 596 — just inside the sidebar, clear of every row's content. Sampled up
// front because the fill would otherwise read back its own output.

let sidebarLeft: CGFloat = 20
let sidebarRight: CGFloat = 600
let sidebarTop = 196
let sidebarBottom = 1908

var wash: [CGColor] = []
for y in sidebarTop..<sidebarBottom { wash.append(pixel(596, y)) }

for (offset, colour) in wash.enumerated() {
    ctx.setFillColor(colour)
    ctx.fill(CGRect(x: sidebarLeft, y: CGFloat(sidebarTop + offset),
                    width: sidebarRight - sidebarLeft, height: 1))
}

struct Project {
    let name: String
    let subtitle: String
    let progress: Double      // negative means "no progress bar"
    let accent: CGColor
    let selected: Bool
}

struct Group {
    let name: String
    let projects: [Project]
}

let blue   = rgb(56, 122, 223)
let orange = rgb(232, 138, 46)
let red    = rgb(228, 86, 74)
let green  = rgb(52, 168, 110)

let groups: [Group] = [
    Group(name: "ACME", projects: [
        Project(name: "acme-storefront", subtitle: "49/92 done", progress: 0.53,
                accent: blue, selected: true),
        Project(name: "acme-api", subtitle: "12/30 done", progress: 0.40,
                accent: red, selected: false),
    ]),
    Group(name: "OPEN SOURCE", projects: [
        Project(name: "claude-workflow-manager", subtitle: "14/15 done", progress: 0.93,
                accent: green, selected: false),
        Project(name: "swift-notes", subtitle: "2/6 done", progress: 0.33,
                accent: blue, selected: false),
    ]),
    Group(name: "SIDE PROJECTS", projects: [
        Project(name: "pocket-timer", subtitle: "3/9 done", progress: 0.33,
                accent: orange, selected: false),
        Project(name: "readerly", subtitle: "acme/readerly", progress: -1,
                accent: blue, selected: false),
    ]),
    Group(name: "ON HOLD", projects: [
        Project(name: "legacy-dashboard", subtitle: "0/7 done", progress: 0,
                accent: blue, selected: false),
    ]),
]

let titleFont = font(30)
let subtitleFont = font(24)
let groupFont = font(23, .semibold)

let rowHeight: CGFloat = 113
let groupHeight: CGFloat = 84

var y: CGFloat = 200

for group in groups {
    draw(group.name, x: 48, baseline: y + 28, groupFont, groupText, tracking: 1.2)

    // The disclosure chevron the real sidebar puts at the right of every group.
    ctx.setStrokeColor(rgb(150, 150, 155))
    ctx.setLineWidth(4)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 545, y: y + 16))
    ctx.addLine(to: CGPoint(x: 560, y: y + 30))
    ctx.addLine(to: CGPoint(x: 575, y: y + 16))
    ctx.strokePath()

    y += groupHeight

    for project in group.projects {
        if project.selected {
            ctx.setFillColor(rgb(205, 219, 222))
            ctx.addPath(rounded(CGRect(x: 32, y: y - 12, width: 554, height: rowHeight - 10), 16))
            ctx.fillPath()
        }

        // Icon tile: the repository-linked projects show a code glyph.
        let tile = CGRect(x: 48, y: y + 6, width: 44, height: 44)
        ctx.setFillColor(project.accent.copy(alpha: 0.18)!)
        ctx.addPath(rounded(tile, 10))
        ctx.fillPath()

        ctx.setStrokeColor(project.accent)
        ctx.setLineWidth(3.5)
        ctx.move(to: CGPoint(x: tile.minX + 16, y: tile.minY + 15))
        ctx.addLine(to: CGPoint(x: tile.minX + 9, y: tile.midY))
        ctx.addLine(to: CGPoint(x: tile.minX + 16, y: tile.maxY - 15))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: tile.maxX - 16, y: tile.minY + 15))
        ctx.addLine(to: CGPoint(x: tile.maxX - 9, y: tile.midY))
        ctx.addLine(to: CGPoint(x: tile.maxX - 16, y: tile.maxY - 15))
        ctx.strokePath()

        draw(project.name, x: 110, baseline: y + 22, titleFont, rgb(28, 28, 30))

        if project.progress >= 0 {
            let track = CGRect(x: 110, y: y + 38, width: 440, height: 6)
            ctx.setFillColor(rgb(199, 199, 204))
            ctx.addPath(rounded(track, 3))
            ctx.fillPath()
            if project.progress > 0 {
                ctx.setFillColor(project.selected ? blue : project.accent)
                ctx.addPath(rounded(CGRect(x: track.minX, y: track.minY,
                                           width: track.width * project.progress,
                                           height: track.height), 3))
                ctx.fillPath()
            }
        }

        draw(project.subtitle, x: 110, baseline: y + 74, subtitleFont, mutedText)

        y += rowHeight
    }
}

// MARK: - The project title in the toolbar

// Both lines start at x = 730 and the block stops short of the toolbar's
// hairline at y = 160; sizes are matched to the capture by comparing the
// original strings' advance per character.
ctx.setFillColor(pixel(1600, 100))
ctx.fill(CGRect(x: 724, y: 64, width: 780, height: 93))
draw("acme-storefront", x: 730, baseline: 105, font(28, .semibold), rgb(28, 28, 30))
draw("acme/acme-storefront", x: 730, baseline: 134, font(22), mutedText)

// MARK: - Emit

let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
