#!/usr/bin/env swift

import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryURL = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputURL = repositoryURL
    .appendingPathComponent("ChessCoach/Assets.xcassets/AppIcon.appiconset")

let outputs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: red / 255,
        green: green / 255,
        blue: blue / 255,
        alpha: alpha
    )
}

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.scaleBy(x: CGFloat(pixels) / 1_024, y: CGFloat(pixels) / 1_024)

    let outer = NSBezierPath(
        roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908),
        xRadius: 214,
        yRadius: 214
    )
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSGradient(
        starting: color(37, 93, 73),
        ending: color(20, 54, 46)
    )?.draw(in: outer, angle: -68)

    NSGraphicsContext.saveGraphicsState()
    let boardFrame = NSRect(x: 178, y: 178, width: 668, height: 668)
    let boardClip = NSBezierPath(
        roundedRect: boardFrame,
        xRadius: 90,
        yRadius: 90
    )
    boardClip.addClip()
    let cell = boardFrame.width / 4
    for rank in 0..<4 {
        for file in 0..<4 {
            let fill = (rank + file).isMultiple(of: 2)
                ? color(239, 226, 193)
                : color(106, 144, 106)
            fill.setFill()
            NSBezierPath(
                rect: NSRect(
                    x: boardFrame.minX + CGFloat(file) * cell,
                    y: boardFrame.minY + CGFloat(rank) * cell,
                    width: cell,
                    height: cell
                )
            ).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    color(28, 70, 57, alpha: 0.94).setFill()
    NSBezierPath(ovalIn: NSRect(x: 274, y: 274, width: 476, height: 476)).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let glyph = NSAttributedString(
        string: "♞",
        attributes: [
            .font: NSFont.systemFont(ofSize: 372, weight: .medium),
            .foregroundColor: color(255, 247, 226),
            .paragraphStyle: paragraph,
        ]
    )
    glyph.draw(in: NSRect(x: 278, y: 292, width: 468, height: 448))

    color(245, 184, 72).setFill()
    NSBezierPath(ovalIn: NSRect(x: 758, y: 766, width: 82, height: 82)).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

try FileManager.default.createDirectory(
    at: outputURL,
    withIntermediateDirectories: true
)
for output in outputs {
    let data = try renderIcon(pixels: output.pixels)
    try data.write(to: outputURL.appendingPathComponent(output.name), options: .atomic)
}
print("Generated \(outputs.count) macOS app icon files.")
