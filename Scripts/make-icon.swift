import AppKit
import Foundation

// Draws the app icon and writes a full .iconset.
//
// Generated rather than hand-drawn so the mark is identical at every size and the palette
// stays tied to the one in Design.swift. The glyph is a fork: a single stroke rising and
// splitting in two — the app's whole argument in one shape, since transferring a
// conversation and branching one are the same move made in different directions.
//
// Flat, no gradient and no bevel. That is a deliberate match for the app's own surface
// rather than an omission.

let canvas = 1024.0
/// macOS icons leave a margin and use a superellipse; 824 in 1024 with a 185pt radius is the
/// proportion Apple's own templates use.
let plateInset = 100.0
let plateSize = canvas - plateInset * 2
let plateRadius = 185.0

let plateColour = NSColor(srgbRed: 0.129, green: 0.125, blue: 0.122, alpha: 1)   // a hair off #1E1E1E
let markColour  = NSColor(srgbRed: 0.851, green: 0.475, blue: 0.349, alpha: 1)   // dark-mode clay

func drawIcon(size: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = size / canvas
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    // Plate
    let plate = NSBezierPath(roundedRect: NSRect(x: plateInset, y: plateInset,
                                                 width: plateSize, height: plateSize),
                             xRadius: plateRadius, yRadius: plateRadius)
    plateColour.setFill()
    plate.fill()

    // Fork. Straight arms with a round join rather than curves: two curves meeting at the
    // split overlapped their own end caps and read as a lump at small sizes, where this
    // glyph has to survive at 16pt.
    let centreX = canvas / 2
    let stemBottom = 300.0
    let split = 545.0
    let armTop = 730.0
    let armSpread = 172.0
    let stroke = 68.0
    let node = 47.0

    markColour.setStroke()
    markColour.setFill()

    // Left arm and the stem are one continuous path so the join is mitred once, not twice.
    let spine = NSBezierPath()
    spine.lineWidth = stroke
    spine.lineCapStyle = .round
    spine.lineJoinStyle = .round
    spine.move(to: NSPoint(x: centreX - armSpread, y: armTop))
    spine.line(to: NSPoint(x: centreX, y: split))
    spine.line(to: NSPoint(x: centreX, y: stemBottom))
    spine.stroke()

    let rightArm = NSBezierPath()
    rightArm.lineWidth = stroke
    rightArm.lineCapStyle = .round
    rightArm.lineJoinStyle = .round
    rightArm.move(to: NSPoint(x: centreX + armSpread, y: armTop))
    rightArm.line(to: NSPoint(x: centreX, y: split))
    rightArm.stroke()

    // Terminals: two destinations and one origin.
    for point in [NSPoint(x: centreX - armSpread, y: armTop),
                  NSPoint(x: centreX + armSpread, y: armTop),
                  NSPoint(x: centreX, y: stemBottom)] {
        NSBezierPath(ovalIn: NSRect(x: point.x - node, y: point.y - node,
                                    width: node * 2, height: node * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/dist/BetterClaude.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let variants: [(name: String, pixels: Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = drawIcon(size: variant.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(variant.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    try data.write(to: url)
}
print("wrote \(variants.count) sizes to \(outputDirectory)")
