#!/usr/bin/env swift
// Draws the disk image window background: an arrow from the app to the Applications link.
// Usage: swift scripts/make-dmg-background.swift <output.png> [scale]
// Layout must match the icon positions in scripts/build-release.sh (600×400 window, icons at x 150/450, y 190).
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments.dropFirst()
guard let outputPath = arguments.first else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output.png> [scale]\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: outputPath)
let scale = CGFloat(Double(arguments.dropFirst().first ?? "1") ?? 1)

let width: CGFloat = 600
let height: CGFloat = 400
let iconCenterY: CGFloat = 190  // Finder coordinates, measured from the top.

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let pixelsWide = Int(width * scale)
let pixelsHigh = Int(height * scale)
guard
    let ctx = CGContext(
        data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("could not create bitmap context") }
ctx.scaleBy(x: scale, y: scale)

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xF7F8FC), color(0xE4E8F4)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// Arrow between the two 128-point icons.
let arrowY = height - iconCenterY
let shaftStart: CGFloat = 235
let tip: CGFloat = 365
let headLength: CGFloat = 26
let headHalfWidth: CGFloat = 20
ctx.setFillColor(color(0x4553B0))
ctx.setStrokeColor(color(0x4553B0))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: shaftStart, y: arrowY))
ctx.addLine(to: CGPoint(x: tip - headLength, y: arrowY))
ctx.strokePath()
ctx.setLineJoin(.round)
ctx.setLineWidth(4)
ctx.move(to: CGPoint(x: tip, y: arrowY))
ctx.addLine(to: CGPoint(x: tip - headLength, y: arrowY + headHalfWidth))
ctx.addLine(to: CGPoint(x: tip - headLength, y: arrowY - headHalfWidth))
ctx.closePath()
ctx.drawPath(using: .fillStroke)

// Caption below the icon labels.
let font = CTFontCreateUIFontForLanguage(.system, 16, nil)!
let caption = NSAttributedString(
    string: "Drag MarkdownBrowser to Applications to install",
    attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x3C4260),
    ])
let line = CTLineCreateWithAttributedString(caption)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: 70)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage(),
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not create \(output.path)") }
let dpi = 72 * scale
CGImageDestinationAddImage(
    destination, image,
    [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
