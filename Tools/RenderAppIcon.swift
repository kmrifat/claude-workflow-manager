// Renders the Claude WM app icon at every size Xcode wants.
//
// Drawn rather than exported so every size is rendered at its own resolution —
// downscaling a 1024 master turns the 16pt card gaps into grey mush.
//
// The mark: three kanban columns, filling left to right, with the single card in
// the last column picked out in amber and lifted. That card is the product —
// work that has been claimed. At 16pt the amber square is still the one thing
// you see, which is the test a small icon has to pass.

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

let deepTeal  = rgb(0x0F5F58)
let darkTeal  = rgb(0x06232A)
let cardLight = rgb(0xEDF5F3)
let amber     = rgb(0xE9A63E)

// MARK: - Geometry helpers

/// Apple's icon grid: the art sits in 824 of 1024, with a continuous corner.
/// Approximated with a circular corner, which is indistinguishable at this
/// radius once the icon is on a dock.
func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The mark, drawn into a 1024-unit box. Callers scale the box.
func drawMark(_ ctx: CGContext, box: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: box.minX, y: box.minY)
    let k = box.width / 1024
    ctx.scaleBy(x: k, y: k)

    // Sized so the mark fills roughly 69% of the box across and 56% down.
    // The first cut used 64/47 and read timid — a mark that small leaves the
    // plate looking like a frame around nothing.
    let columnWidth: CGFloat = 190
    let gap: CGFloat = 68
    let xs: [CGFloat] = [159, 159 + columnWidth + gap, 159 + 2 * (columnWidth + gap)]

    let headerY: CGFloat = 223
    let headerH: CGFloat = 28
    let cardH: CGFloat = 150
    let cardGap: CGFloat = 30
    let firstCardY: CGFloat = 291
    let counts = [3, 2, 1]

    // Column headers — these are what stop the mark reading as a bar chart.
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
            // The claimed card sits a little proud of the others. Invisible at
            // 16pt, but it gives the large sizes somewhere for the eye to land.
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

// MARK: - Rendering

enum Style { case macOS, iOS }

func render(size: Int, style: Style) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Work top-down, the way the numbers above are written.
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
        ctx.setFillColor(darkTeal)
        ctx.addPath(roundedPath(plate, radius))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(radius > 0 ? roundedPath(plate, radius) : CGPath(rect: plate, transform: nil))
    ctx.clip()

    // Diagonal ground, lit from the top-left so the plate reads as a surface.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [deepTeal, darkTeal] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: []
    )

    // A soft highlight in the top-left corner, well under the point of notice.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(0x8FE8DF, 0.20), rgb(0x8FE8DF, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: plate.minX + plate.width * 0.22, y: plate.minY + plate.height * 0.18),
        startRadius: 0,
        endCenter: CGPoint(x: plate.minX + plate.width * 0.22, y: plate.minY + plate.height * 0.18),
        endRadius: plate.width * 0.72,
        options: []
    )

    // The mark is inset within the plate so it never crowds the corners.
    let markInset = plate.width * 0.06
    drawMark(ctx, box: plate.insetBy(dx: markInset, dy: markInset))
    ctx.restoreGState()

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
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "claude-wm-icon-mac.png"))
write(render(size: 1024, style: .iOS),
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "claude-wm-icon-ios.png"))

print("wrote \(macSizes.count) macOS sizes + 1 iOS")
