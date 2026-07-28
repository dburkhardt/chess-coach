#!/usr/bin/env swift

import AppKit
import Foundation

private let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.count >= 3 else {
    fputs(
        "Usage: make-visual-qa-contact-sheet.swift OUTPUT.png INPUT.png [INPUT.png ...]\n",
        stderr
    )
    exit(64)
}

let outputURL = URL(fileURLWithPath: arguments[0])
let inputURLs = arguments.dropFirst().map(URL.init(fileURLWithPath:))
let loadedImages: [(url: URL, image: NSImage)] = inputURLs.compactMap { url in
    guard let image = NSImage(contentsOf: url) else {
        return nil
    }
    return (url, image)
}

guard loadedImages.count == inputURLs.count else {
    fputs("Could not read every visual-QA PNG.\n", stderr)
    exit(65)
}

let columns = 2
let cellWidth: CGFloat = 900
let imageHeight: CGFloat = 610
let labelHeight: CGFloat = 48
let gutter: CGFloat = 24
let margin: CGFloat = 32
let rows = Int(ceil(Double(loadedImages.count) / Double(columns)))
let canvasWidth = margin * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gutter
let canvasHeight = margin * 2 + CGFloat(rows) * (imageHeight + labelHeight) + CGFloat(rows - 1) * gutter

guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasWidth),
        pixelsHigh: Int(canvasHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
else {
    fputs("Could not create contact-sheet bitmap.\n", stderr)
    exit(70)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create contact-sheet graphics context.\n", stderr)
    exit(70)
}
NSGraphicsContext.current = context

NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)).fill()

let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: NSColor.white,
]

for (index, item) in loadedImages.enumerated() {
    let row = index / columns
    let column = index % columns
    let x = margin + CGFloat(column) * (cellWidth + gutter)
    let yFromTop = margin + CGFloat(row) * (imageHeight + labelHeight + gutter)
    let labelY = canvasHeight - yFromTop - labelHeight
    let imageY = labelY - imageHeight

    let sourceSize = item.image.size
    let scale = min(cellWidth / sourceSize.width, imageHeight / sourceSize.height)
    let drawnSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let imageRect = NSRect(
        x: x + (cellWidth - drawnSize.width) / 2,
        y: imageY + (imageHeight - drawnSize.height) / 2,
        width: drawnSize.width,
        height: drawnSize.height
    )

    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: x, y: imageY, width: cellWidth, height: imageHeight),
        xRadius: 10,
        yRadius: 10
    ).fill()
    item.image.draw(
        in: imageRect,
        from: NSRect(origin: .zero, size: sourceSize),
        operation: .sourceOver,
        fraction: 1
    )

    let label = item.url.deletingPathExtension().lastPathComponent
    label.draw(
        at: NSPoint(x: x, y: labelY + 10),
        withAttributes: labelAttributes
    )
}

NSGraphicsContext.restoreGraphicsState()

guard
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not encode contact sheet as PNG.\n", stderr)
    exit(70)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write contact sheet: \(error)\n", stderr)
    exit(74)
}
