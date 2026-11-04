#!/usr/bin/env swift
// Draws the app icon at every size into an asset catalog icon set.
// Usage: swift scripts/make-icon.swift [MarkdownBrowser/Assets.xcassets/AppIcon.appiconset]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSet = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "MarkdownBrowser/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A closed polygon with each corner rounded by its own radius.
func roundedPolygon(_ points: [(CGPoint, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let last = points[points.count - 1].0
    let first = points[0].0
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for (index, (corner, radius)) in points.enumerated() {
        let next = points[(index + 1) % points.count].0
        path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
    }
    path.closeSubpath()
    return path
}

/// The CC0 Markdown mark (github.com/dcurtis/markdown-mark), in its 208×128 SVG coordinates.
func markdownMark() -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: 30, y: 98), CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 30), CGPoint(x: 70, y: 55),
        CGPoint(x: 90, y: 30), CGPoint(x: 110, y: 30), CGPoint(x: 110, y: 98), CGPoint(x: 90, y: 98),
        CGPoint(x: 90, y: 59), CGPoint(x: 70, y: 84), CGPoint(x: 50, y: 59), CGPoint(x: 50, y: 98),
    ])
    path.closeSubpath()
    path.addLines(between: [
        CGPoint(x: 155, y: 98), CGPoint(x: 125, y: 65), CGPoint(x: 145, y: 65), CGPoint(x: 145, y: 30),
        CGPoint(x: 165, y: 30), CGPoint(x: 165, y: 65), CGPoint(x: 185, y: 65),
    ])
    path.closeSubpath()
    return path
}

/// Draws in a 1024-point, y-up space following the macOS icon grid (824-point body).
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)

    let body = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, alpha: 0.3))
    ctx.addPath(body)
    ctx.setFillColor(color(0x2B3A9E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x5C7CFA), color(0x2B3A9E)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let fold: CGFloat = 140
    let (left, right, bottom, top): (CGFloat, CGFloat, CGFloat, CGFloat) = (252, 772, 190, 834)
    let page = roundedPolygon([
        (CGPoint(x: left, y: bottom), 40), (CGPoint(x: right, y: bottom), 40),
        (CGPoint(x: right, y: top - fold), 10), (CGPoint(x: right - fold, y: top), 10), (CGPoint(x: left, y: top), 40),
    ])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x10164A, alpha: 0.35))
    ctx.addPath(page)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(roundedPolygon([
        (CGPoint(x: right - fold, y: top), 10), (CGPoint(x: right - fold, y: top - fold), 24),
        (CGPoint(x: right, y: top - fold), 10),
    ]))
    ctx.setFillColor(color(0xC9D2F8))
    ctx.fillPath()

    // Text lines blur into noise below 64 pixels.
    if pixels >= 64 {
        ctx.setFillColor(color(0xD3D9F2))
        for (y, width) in [(708, 270), (636, 420), (564, 350)] as [(CGFloat, CGFloat)] {
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: left + 64, y: y, width: width, height: 34), cornerWidth: 17, cornerHeight: 17,
                transform: nil))
        }
        ctx.fillPath()
    }

    let markWidth: CGFloat = 400
    let markScale = markWidth / 208
    var transform = CGAffineTransform(translationX: 512 - markWidth / 2, y: 250 + 128 * markScale)
        .scaledBy(x: markScale, y: -markScale)
    ctx.setStrokeColor(color(0x2B3A9E))
    ctx.setLineWidth(12 * markScale)
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 6, y: 6, width: 196, height: 116), cornerWidth: 12, cornerHeight: 12,
        transform: &transform))
    ctx.strokePath()
    ctx.addPath(markdownMark().copy(using: &transform)!)
    ctx.setFillColor(color(0x2B3A9E))
    ctx.fillPath()
}

func writePNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx, pixels: pixels)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try writePNG(pixels: size * scale, to: iconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconSet.path)")
