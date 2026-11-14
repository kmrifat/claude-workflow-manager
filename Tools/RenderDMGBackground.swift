// Renders the background of the installer window — the one the DMG opens to,
// with Pitwall on the left, Applications on the right and an arrow between.
//
// Drawn here for the reason RenderBanner.swift is: the palette lives in one
// place, so the installer cannot drift from the icon and the banner.
//
// Finder draws the icons and their names on top of this picture, and it draws
// the names white in Dark Mode and black in Light Mode whatever the picture
// is. So each name sits on a mid-tone plate that both colours read on; on the
// navy alone, a black "Applications" would be invisible to half the people
// opening the disk image. The icon positions here and in release.sh's dmgbuild
// settings are the same numbers — change one, change both.
//
// Usage:
//   xcrun swift Tools/RenderDMGBackground.swift <out-dir>
//   → <out-dir>/background.png      (660×400, 1x)
//   → <out-dir>/background@2x.png   (1320×800, 2x)

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (RenderAppIcon.swift's; change one, change both)

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

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Layout, in points (top-left origin)

let size = CGSize(width: 660, height: 400)
/// Icon centres. release.sh hands Finder these same two points.
let appCentre = CGPoint(x: 170, y: 200)
let applicationsCentre = CGPoint(x: 490, y: 200)
let iconSize: CGFloat = 128
/// Where Finder puts a name: centred, starting this far below the icon centre.
let labelTop: CGFloat = 72
let labelHeight: CGFloat = 22

/// About 0.19 relative luminance: white text and black text both clear 4.4:1
/// on it, which is the point — see the header.
let plate = rgb(0x707890)

// MARK: - Text

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

func line(_ text: String, font f: CTFont, color: CGColor, tracking: CGFloat = 0) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: f, .foregroundColor: color, .kern: tracking,
    ]))
}

/// Draws `text` centred on `x`, with its baseline at `baseline`. The context is
/// flipped top-down, so each line gets a second flip about its own baseline.
func drawCentred(_ text: String, _ ctx: CGContext, x: CGFloat, baseline: CGFloat,
                 font f: CTFont, color: CGColor, tracking: CGFloat = 0) {
    let l = line(text, font: f, color: color, tracking: tracking)
    let width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    ctx.saveGState()
    ctx.translateBy(x: x - width / 2, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(l, ctx)
    ctx.restoreGState()
}

// MARK: - Render

func render(scale: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: Int(size.width * scale), height: Int(size.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: size.height * scale)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high

    let W = size.width, H = size.height

    // Ground: the icon's midnight, with the banner's faint orange-red wash, here
    // aimed at the arrow, so the eye lands between the two icons.
    ctx.drawLinearGradient(gradient([midnightTop, midnightBottom]),
                           start: .zero, end: CGPoint(x: W * 0.4, y: H),
                           options: [.drawsAfterEndLocation])
    ctx.drawRadialGradient(
        gradient([rgb(0xFF4F1F, 0.16), rgb(0xFF4F1F, 0)]),
        startCenter: CGPoint(x: W / 2, y: appCentre.y), startRadius: 0,
        endCenter: CGPoint(x: W / 2, y: appCentre.y), endRadius: W * 0.42,
        options: []
    )

    // The heading.
    drawCentred("Install Pitwall", ctx, x: W / 2, baseline: 62,
                font: font(24, .bold), color: rgb(0xFFFFFF), tracking: -0.3)
    drawCentred("Drag Pitwall onto the Applications folder.", ctx, x: W / 2, baseline: 88,
                font: font(13, .regular), color: rgb(0xFFFFFF, 0.62))

    // A soft well behind each icon, so they read as two places rather than two
    // pictures floating on a gradient.
    for centre in [appCentre, applicationsCentre] {
        let well = CGRect(x: centre.x - 92, y: centre.y - 84, width: 184, height: 196)
        ctx.setFillColor(rgb(0xFFFFFF, 0.05))
        ctx.addPath(roundedPath(well, 26))
        ctx.fillPath()
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.09))
        ctx.setLineWidth(1)
        ctx.addPath(roundedPath(well.insetBy(dx: 0.5, dy: 0.5), 26))
        ctx.strokePath()
    }

    // The name plates (see the header for why they exist at all).
    for (centre, width) in [(appCentre, CGFloat(92)), (applicationsCentre, CGFloat(128))] {
        let rect = CGRect(x: centre.x - width / 2, y: centre.y + labelTop - 2,
                          width: width, height: labelHeight)
        ctx.setFillColor(plate)
        ctx.addPath(roundedPath(rect, labelHeight / 2))
        ctx.fillPath()
    }

    // The arrow: the leader bar's gradient, with its glow.
    let start = CGPoint(x: appCentre.x + iconSize / 2 + 30, y: appCentre.y)
    let tip = CGPoint(x: applicationsCentre.x - iconSize / 2 - 26, y: applicationsCentre.y)
    let thickness: CGFloat = 10
    let head: CGFloat = 26

    let shaft = CGPath(
        roundedRect: CGRect(x: start.x, y: start.y - thickness / 2,
                            width: tip.x - start.x - head * 0.6, height: thickness),
        cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)
    let arrowhead = CGMutablePath()
    arrowhead.move(to: CGPoint(x: tip.x, y: tip.y))
    arrowhead.addLine(to: CGPoint(x: tip.x - head, y: tip.y - head * 0.8))
    arrowhead.addQuadCurve(to: CGPoint(x: tip.x - head, y: tip.y + head * 0.8),
                           control: CGPoint(x: tip.x - head * 0.55, y: tip.y))
    arrowhead.closeSubpath()
    // One outline, not two subpaths: the shaft and the head wind in opposite
    // directions, and filled together their overlap cancels into a hole.
    let arrow = shaft.union(arrowhead)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: rgb(0xFF4F1F, 0.6))
    ctx.setFillColor(rgb(0xFF4F1F))
    ctx.addPath(arrow)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    ctx.drawLinearGradient(gradient([accentStart, accentEnd]),
                           start: CGPoint(x: start.x, y: start.y),
                           end: CGPoint(x: tip.x, y: tip.y), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Emit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let url = out.appending(path: name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    // 72 dpi at 1x and 144 at 2x is how Finder tells the two apart once they
    // are combined into one TIFF.
    let dpi = 72 * scale
    CGImageDestinationAddImage(dest, render(scale: scale), [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}
