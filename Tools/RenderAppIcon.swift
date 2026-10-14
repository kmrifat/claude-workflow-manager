// Renders the Pitwall app icon at every size Xcode wants.
//
// Drawn rather than exported so every size is rendered at its own resolution —
// downscaling a 1024 master turns thin bars into grey mush.
//
// The mark is a timing tower, the screen on a race team's pit wall: one bar per
// project, the leader lit in orange-red with a live dot, the next carrying an
// orange-red "needs you" signal, the rest fading back. Orange-red is the only
// accent; everything else is midnight and white. The design lives in
// design/ClaudeWM.fig › Branding · Pitwall (local only — see .gitignore).
//
// Coordinates below are in the design's 412-unit body, the art area of a
// 512-unit canvas (Apple's 824-of-1024 grid at half scale).
//
// Run from the repository root:
//
//   swift Tools/RenderAppIcon.swift .

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

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

// MARK: - Rendering

enum Style { case macOS, iOS }

func render(size: Int, style: Style) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Work top-down, the way the design's numbers are written.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS insets the art inside the canvas and rounds it itself; iOS is
    // full-bleed and the system applies the mask.
    let plate: CGRect
    let radius: CGFloat
    switch style {
    case .macOS:
        let inset = s * (100.0 / 1024.0)
        plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        radius = plate.width * 0.2237
    case .iOS:
        plate = CGRect(x: 0, y: 0, width: s, height: s)
        radius = 0
    }

    if style == .macOS {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.022,
                      color: rgb(0x000000, 0.32))
        ctx.setFillColor(midnightBottom)
        ctx.addPath(roundedPath(plate, radius))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(radius > 0 ? roundedPath(plate, radius) : CGPath(rect: plate, transform: nil))
    ctx.clip()

    // Midnight, lifting towards the top so the plate reads as a surface.
    ctx.drawLinearGradient(gradient([midnightTop, midnightBottom]),
                           start: CGPoint(x: plate.midX, y: plate.minY),
                           end: CGPoint(x: plate.midX, y: plate.maxY), options: [])
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: plate.midX, y: plate.minY),
                           end: CGPoint(x: plate.midX, y: plate.midY), options: [])

    drawTower(ctx, body: plate, layout: size <= 32 ? .small : .full, glow: size >= 64)
    ctx.restoreGState()

    // A hairline edge, so the dark plate holds its shape on a dark Dock.
    if style == .macOS && size >= 64 {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
        ctx.setLineWidth(max(1, s / 512))
        ctx.addPath(roundedPath(plate.insetBy(dx: 0.5, dy: 0.5), radius))
        ctx.strokePath()
    }

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Emit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let macDir = root.appending(path: "workflow-manager/Assets.xcassets/AppIcon.appiconset")
let iosDir = root.appending(path: "ClaudeWMMobile/Assets.xcassets/AppIcon.appiconset")
for dir in [macDir, iosDir] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// macOS: every size rendered natively, not downscaled from one master.
let macSizes: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
var macEntries: [[String: String]] = []
for (pt, scale) in macSizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    write(render(size: px, style: .macOS), to: macDir.appending(path: name))
    macEntries.append([
        "filename": name, "idiom": "mac",
        "scale": "\(scale)x", "size": "\(pt)x\(pt)",
    ])
}

write(render(size: 1024, style: .iOS), to: iosDir.appending(path: "icon_1024.png"))

func writeJSON(_ images: [[String: String]], to dir: URL) throws {
    let payload: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: dir.appending(path: "Contents.json"))
}

try writeJSON(macEntries, to: macDir)
try writeJSON(
    [["filename": "icon_1024.png", "idiom": "universal",
      "platform": "ios", "size": "1024x1024"]],
    to: iosDir
)

// A preview at display size for the human deciding whether they like it.
write(render(size: 1024, style: .macOS),
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pitwall-icon-mac.png"))
write(render(size: 1024, style: .iOS),
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pitwall-icon-ios.png"))

print("wrote \(macSizes.count) macOS sizes + 1 iOS")
