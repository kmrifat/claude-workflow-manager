// Renders the README banner.
//
// Drawn rather than mocked up in a design tool for the same reason
// RenderAppIcon.swift is: the palette and the mark live in one place, so a
// change to the product's colours cannot leave the banner behind. The tower
// here is deliberately the icon's own — same rows, same orange-red leader, same
// signal dot — because a banner that shows a different mark than the Dock icon
// reads as a different product.
//
// Usage:
//   xcrun swift Tools/RenderBanner.swift <repo-root>
//   → <repo-root>/Docs/banner.png   (2400×640, for a 1200pt-wide README)

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
//
// Kept byte-identical to RenderAppIcon.swift. If you change one, change both.

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green:   CGFloat((hex >> 8) & 0xFF) / 255,
        blue:    CGFloat(hex & 0xFF) / 255,
        alpha:   a
    )
}

let midnightTop    = rgb(0x1C2A4A)
let midnightBottom = rgb(0x080D1A)
let accentStart    = rgb(0xF2380F)
let accentEnd      = rgb(0xFF7A3D)
let accent         = rgb(0xFF4F1F)
let paper          = rgb(0xF3F3F6)
let paperShade     = rgb(0xD9DEE8)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
}

// MARK: - The tower

/// One row of the tower, in body units.
struct Row {
    var y: CGFloat
    var barWidth: CGFloat
    enum Kind { case leader, signal, faded(CGFloat) }
    var kind: Kind
}

struct Layout {
    var rowHeight: CGFloat
    var chipX: CGFloat
    var barX: CGFloat
    var rows: [Row]
    var dot: CGFloat

    /// Four rows: the design as drawn.
    static let full = Layout(
        rowHeight: 50, chipX: 56, barX: 122,
        rows: [
            Row(y: 73,  barWidth: 234, kind: .leader),
            Row(y: 145, barWidth: 190, kind: .signal),
            Row(y: 217, barWidth: 150, kind: .faded(0.55)),
            Row(y: 289, barWidth: 108, kind: .faded(0.30)),
        ],
        dot: 18
    )

    /// Three thicker rows for 32 px and below. Four 1.5 px bars at 16 px read
    /// as hatching; three bars still read as a tower with a lit leader.
    static let small = Layout(
        rowHeight: 66, chipX: 52, barX: 134,
        rows: [
            Row(y: 84,  barWidth: 230, kind: .leader),
            Row(y: 173, barWidth: 180, kind: .signal),
            Row(y: 262, barWidth: 124, kind: .faded(0.50)),
        ],
        dot: 26
    )
}

/// Draws the tower into `body`, a square in canvas coordinates.
func drawTower(_ ctx: CGContext, body: CGRect, layout: Layout, glow: Bool) {
    let k = body.width / 412
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: body.minX + x * k, y: body.minY + y * k, width: w * k, height: h * k)
    }
    let h = layout.rowHeight

    for row in layout.rows {
        // The position chip on the left.
        let chip = r(layout.chipX, row.y, h, h)
        switch row.kind {
        case .leader: ctx.setFillColor(rgb(0xFF4F1F, 0.35))
        case .signal: ctx.setFillColor(rgb(0xFFFFFF, 0.12))
        case .faded(let a): ctx.setFillColor(rgb(0xFFFFFF, a * 0.15))
        }
        ctx.addPath(roundedPath(chip, h * 0.28 * k))
        ctx.fillPath()

        // The bar.
        let bar = r(layout.barX, row.y, row.barWidth, h)
        let barPath = roundedPath(bar, h / 2 * k)
        switch row.kind {
        case .leader:
            ctx.saveGState()
            if glow {
                ctx.setShadow(offset: .zero, blur: 30 * k, color: rgb(0xFF4F1F, 0.65))
                ctx.setFillColor(accent)
                ctx.addPath(barPath)
                ctx.fillPath()
            }
            ctx.addPath(barPath)
            ctx.clip()
            ctx.drawLinearGradient(gradient([accentStart, accentEnd]),
                                   start: CGPoint(x: bar.minX, y: bar.midY),
                                   end: CGPoint(x: bar.maxX, y: bar.midY), options: [])
            ctx.restoreGState()
        case .signal:
            ctx.saveGState()
            ctx.addPath(barPath)
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), paperShade]),
                                   start: CGPoint(x: bar.midX, y: bar.minY),
                                   end: CGPoint(x: bar.midX, y: bar.maxY), options: [])
            ctx.restoreGState()
        case .faded(let a):
            ctx.setFillColor(rgb(0xF3F3F6, a))
            ctx.addPath(barPath)
            ctx.fillPath()
        }

        // The dot at the bar's end: white and live on the leader, the accent
        // on the next — the one asking for you.
        let d = layout.dot
        let dotRect = r(layout.barX + row.barWidth - (h - d) / 2 - d, row.y + (h - d) / 2, d, d)
        switch row.kind {
        case .leader:
            ctx.setFillColor(rgb(0xFFFFFF))
            ctx.fillEllipse(in: dotRect)
        case .signal:
            ctx.saveGState()
            if glow { ctx.setShadow(offset: .zero, blur: 10 * k, color: rgb(0xFF4F1F, 0.65)) }
            ctx.setFillColor(accent)
            ctx.fillEllipse(in: dotRect)
            ctx.restoreGState()
        case .faded:
            break
        }
    }
}

// MARK: - Text
//
// The context is flipped top-down so the layout numbers read the way they are
// written. CoreText lays glyphs out bottom-up regardless, so each line is drawn
// inside a second flip about its own baseline — otherwise the text renders
// upside down, which is the classic symptom of drawing CoreText into a flipped
// CGContext.

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

/// Draws `text` with its left edge at `x` and its *cap height* sitting on
/// `baseline`, and returns the width consumed.
@discardableResult
func draw(
    _ text: String,
    _ ctx: CGContext,
    x: CGFloat,
    baseline: CGFloat,
    font f: CTFont,
    color: CGColor,
    tracking: CGFloat = 0
) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: f,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )

    ctx.saveGState()
    ctx.translateBy(x: x, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// MARK: - Render

// Sized so the right margin matches the left: the tagline is the widest line,
// and a banner with 500px of dead air on one side reads as a cropping mistake.
let width = 2020
let height = 640

let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let W = CGFloat(width)
let H = CGFloat(height)

ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)

// Ground: the icon's midnight, run across a much wider box so the right-hand
// end stays dark enough for white text to sit on it.
ctx.drawLinearGradient(gradient([midnightTop, midnightBottom]),
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: W * 0.55, y: H),
                       options: [.drawsAfterEndLocation])

// A faint orange-red wash behind the tile, aimed at the leader bar. Well under
// the point of notice — it exists so the left half is not flat navy.
ctx.drawRadialGradient(
    gradient([rgb(0xFF4F1F, 0.14), rgb(0xFF4F1F, 0)]),
    startCenter: CGPoint(x: W * 0.17, y: H * 0.40), startRadius: 0,
    endCenter: CGPoint(x: W * 0.17, y: H * 0.40), endRadius: W * 0.28,
    options: []
)

// --- The icon tile -----------------------------------------------------------
//
// Drawn as the app's own rounded plate rather than a bare mark, so the banner
// shows the thing that will actually be in the reader's Dock.

let tileSize: CGFloat = 380
let tile = CGRect(x: 150, y: (H - tileSize) / 2, width: tileSize, height: tileSize)
let tileRadius = tileSize * 0.2237

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: rgb(0x000000, 0.55))
ctx.setFillColor(midnightBottom)
ctx.addPath(roundedPath(tile, tileRadius))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(roundedPath(tile, tileRadius))
ctx.clip()
ctx.drawLinearGradient(gradient([midnightTop, midnightBottom]),
                       start: CGPoint(x: tile.midX, y: tile.minY),
                       end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0)]),
                       start: CGPoint(x: tile.midX, y: tile.minY),
                       end: CGPoint(x: tile.midX, y: tile.midY), options: [])
drawTower(ctx, body: tile, layout: .full, glow: true)
ctx.restoreGState()

// The icon's hairline edge, which is what keeps the tile from looking pasted on.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(2)
ctx.addPath(roundedPath(tile.insetBy(dx: 1, dy: 1), tileRadius))
ctx.strokePath()

// --- Wordmark ----------------------------------------------------------------

let textX = tile.maxX + 110

draw("Pitwall", ctx,
     x: textX, baseline: 235,
     font: font(132, .bold), color: rgb(0xFFFFFF), tracking: -3)

draw("Every project you run on one macOS board, GitHub", ctx,
     x: textX, baseline: 317,
     font: font(46, .regular), color: rgb(0xFFFFFF, 0.72))

draw("issues included — with Claude Code working the cards.", ctx,
     x: textX, baseline: 381,
     font: font(46, .regular), color: rgb(0xFFFFFF, 0.72))

// --- Footer chips ------------------------------------------------------------
//
// The three things a reader wants to know before clicking Download, in the
// order they would ask: what it needs, what it is, what it costs them.

let chips = ["macOS 14+", "Apple Silicon & Intel", "SwiftUI · SwiftData"]
var chipX = textX
let chipFont = font(34, .medium)

for chip in chips {
    let textWidth = CGFloat(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(
            NSAttributedString(string: chip, attributes: [.font: chipFont, .kern: 0.5])
        ), nil, nil, nil))
    let padding: CGFloat = 30
    let chipRect = CGRect(x: chipX, y: 435, width: textWidth + padding * 2, height: 66)

    ctx.setFillColor(rgb(0xFFFFFF, 0.09))
    ctx.addPath(roundedPath(chipRect, 33))
    ctx.fillPath()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(2)
    ctx.addPath(roundedPath(chipRect, 33))
    ctx.strokePath()

    draw(chip, ctx,
         x: chipX + padding, baseline: 480,
         font: chipFont, color: rgb(0xFFFFFF, 0.80), tracking: 0.5)

    chipX = chipRect.maxX + 22
}

// MARK: - Emit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let docs = root.appending(path: "Docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

let out = docs.appending(path: "banner.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)

print("wrote \(out.path)")
