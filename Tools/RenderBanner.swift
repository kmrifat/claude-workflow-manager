// Renders the README banner.
//
// Drawn rather than mocked up in a design tool for the same reason
// RenderAppIcon.swift is: the palette and the mark live in one place, so a
// change to the product's colours cannot leave the banner behind. The mark
// geometry here is deliberately the same as the icon's — three columns filling
// left to right, the single claimed card picked out in amber — because a banner
// that shows a different mark than the dock icon reads as a different product.
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

let deepTeal  = rgb(0x0F5F58)
let darkTeal  = rgb(0x06232A)
let cardLight = rgb(0xEDF5F3)
let amber     = rgb(0xE9A63E)

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - The mark
//
// The 1024-unit box and every number in it are the icon's. Callers scale.

func drawMark(_ ctx: CGContext, box: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: box.minX, y: box.minY)
    let k = box.width / 1024
    ctx.scaleBy(x: k, y: k)

    let columnWidth: CGFloat = 190
    let gap: CGFloat = 68
    let xs: [CGFloat] = [159, 159 + columnWidth + gap, 159 + 2 * (columnWidth + gap)]

    let headerY: CGFloat = 223
    let headerH: CGFloat = 28
    let cardH: CGFloat = 150
    let cardGap: CGFloat = 30
    let firstCardY: CGFloat = 291
    let counts = [3, 2, 1]

    for x in xs {
        ctx.setFillColor(rgb(0xFFFFFF, 0.30))
        ctx.addPath(roundedPath(
            CGRect(x: x, y: headerY, width: columnWidth, height: headerH),
            headerH / 2
        ))
        ctx.fillPath()
    }

    for (column, x) in xs.enumerated() {
        for row in 0..<counts[column] {
            let isClaimed = (column == 2)
            let lift: CGFloat = isClaimed ? 18 : 0
            let y = firstCardY + CGFloat(row) * (cardH + cardGap) - lift
            let rect = CGRect(x: x, y: y, width: columnWidth, height: cardH)

            if isClaimed {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 34,
                              color: rgb(0x000000, 0.42))
            }
            ctx.setFillColor(isClaimed ? amber : cardLight)
            ctx.addPath(roundedPath(rect, 30))
            ctx.fillPath()
            if isClaimed { ctx.restoreGState() }
        }
    }

    ctx.restoreGState()
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

// Ground: the icon's diagonal gradient, run across a much wider box so the
// right-hand end stays dark enough for white text to sit on it.
let ground = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [deepTeal, darkTeal] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    ground,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: W, y: H),
    options: []
)

// The same top-left sheen the icon has, so the two read as one surface.
let sheen = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgb(0x8FE8DF, 0.18), rgb(0x8FE8DF, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: W * 0.18, y: H * 0.10), startRadius: 0,
    endCenter: CGPoint(x: W * 0.18, y: H * 0.10), endRadius: W * 0.55,
    options: []
)

// A faint amber wash behind the tile, aimed at the claimed card. Well under the
// point of notice — it exists so the right half is not flat black-green.
let warmth = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgb(0xE9A63E, 0.13), rgb(0xE9A63E, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    warmth,
    startCenter: CGPoint(x: W * 0.20, y: H * 0.62), startRadius: 0,
    endCenter: CGPoint(x: W * 0.20, y: H * 0.62), endRadius: W * 0.30,
    options: []
)

// --- The icon tile -----------------------------------------------------------
//
// Drawn as the app's own rounded plate rather than a bare mark, so the banner
// shows the thing that will actually be in the reader's dock.

let tileSize: CGFloat = 380
let tile = CGRect(x: 150, y: (H - tileSize) / 2, width: tileSize, height: tileSize)
let tileRadius = tileSize * 0.2237

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: rgb(0x000000, 0.45))
ctx.setFillColor(rgb(0x0A3138))
ctx.addPath(roundedPath(tile, tileRadius))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(roundedPath(tile, tileRadius))
ctx.clip()
ctx.drawLinearGradient(
    ground,
    start: CGPoint(x: tile.minX, y: tile.minY),
    end: CGPoint(x: tile.maxX, y: tile.maxY),
    options: []
)
drawMark(ctx, box: tile.insetBy(dx: tileSize * 0.06, dy: tileSize * 0.06))
ctx.restoreGState()

// A hairline lip along the top edge, which is what keeps the tile from looking
// pasted on.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(2)
ctx.addPath(roundedPath(tile.insetBy(dx: 1, dy: 1), tileRadius))
ctx.strokePath()

// --- Wordmark ----------------------------------------------------------------

let textX = tile.maxX + 110

draw("Claude WM", ctx,
     x: textX, baseline: 235,
     font: font(132, .bold), color: rgb(0xFFFFFF), tracking: -3)

draw("A macOS kanban board that mirrors your GitHub issues", ctx,
     x: textX, baseline: 317,
     font: font(46, .regular), color: rgb(0xFFFFFF, 0.72))

draw("and hands work to Claude Code — without leaving the window.", ctx,
     x: textX, baseline: 381,
     font: font(46, .regular), color: rgb(0xFFFFFF, 0.72))

// --- Footer chips ------------------------------------------------------------
//
// The three things a reader wants to know before clicking Download, in the
// order they would ask: what it needs, what it is, what it costs them.

let chips = ["macOS 26.5+", "Apple Silicon", "SwiftUI · SwiftData"]
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
