import AppKit
import Foundation

// Draws the app icon from one geometry.
//
//   make-icon <AppIcon.icon>               an Icon Composer bundle, compiled by actool
//   make-icon --accent <Assets.xcassets>   the app's accent colour, Lagoon, for the same pass
//   make-icon --png <file.png> <size>      a flat rendering, for the website and touch icon
//
// The mark is a heavy lowercase b. Its square bottom-left corner is a speech bubble's tail,
// and its counter is a smaller speech bubble. Generated rather than drawn by hand, so the
// icon, the in-app mark (BMark in Components.swift) and the website never drift apart.
//
// Nothing is painted for depth: the system adds the glass, highlights and shadow to the
// Icon Composer layers in every appearance (default, dark, clear and tinted).

let canvas = 1024.0
/// The glyph's own box on the 1024 grid, and how much it is enlarged about the centre.
let glyphCentre = (x: 518.0, y: 515.0)
let glyphScale = 1.1

let backgroundSRGB = (0.047, 0.106, 0.141)   // #0C1B24, deep ink
let glyphHex = "#35C8F0"                      // Lagoon, bright

/// The b, in SVG path syntax on a 1024 grid with y pointing down.
let glyphPath = "M268 300 a58 58 0 0 1 116 0 V 388 A 228 228 0 1 1 540 788 H 268 Z " +
                "M540 474 a96 96 0 1 1 0 192 H 444 V 570 a96 96 0 0 1 96 -96 Z"

let transform = "translate(512 512) scale(\(glyphScale)) translate(\(-glyphCentre.x) \(-glyphCentre.y))"

func writeIconBundle(to bundle: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: bundle)
    try fm.createDirectory(at: bundle.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
    <path transform="\(transform)" fill-rule="evenodd" fill="\(glyphHex)" d="\(glyphPath)"/></svg>
    """
    try Data(svg.utf8).write(to: bundle.appendingPathComponent("Assets/b.svg"))
    let (r, g, b) = backgroundSRGB
    let json = """
    {
      "fill" : { "solid" : "srgb:\(String(format: "%.5f,%.5f,%.5f", r, g, b)),1.00000" },
      "groups" : [
        {
          "layers" : [ { "image-name" : "b.svg", "name" : "b" } ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : true, "value" : 0.4 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try Data(json.utf8).write(to: bundle.appendingPathComponent("icon.json"))
}

/// A flat rendering on the macOS icon grid (824 of 1024, continuous corners).
func writePNG(to file: URL, size: Int) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = Double(size) / canvas
    // Flip to the SVG's y-down grid.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    let (r, g, b) = backgroundSRGB
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: glyphScale, y: glyphScale)
    context.translateBy(x: -glyphCentre.x, y: -glyphCentre.y)
    context.addPath(BPath.make())
    context.setFillColor(NSColor(srgbRed: 0.208, green: 0.784, blue: 0.941, alpha: 1).cgColor)
    context.fillPath(using: .evenOdd)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: file)
}

/// The same b as `glyphPath`, as a CGPath (y down), for the flat rendering.
enum BPath {
    static func arc(_ path: CGMutablePath, cx: Double, cy: Double, r: Double, from: Double, to: Double) {
        let steps = 64
        for i in 1...steps {
            let t = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
            path.addLine(to: CGPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
        }
    }

    static func make() -> CGPath {
        let path = CGMutablePath()
        // Stem with a round top, then the bowl, then the square tail.
        path.move(to: CGPoint(x: 268, y: 300))
        arc(path, cx: 326, cy: 300, r: 58, from: 180, to: 360)
        let joinY = 560 - (228.0 * 228 - 156 * 156).squareRoot()
        path.addLine(to: CGPoint(x: 384, y: joinY))
        let start = atan2(joinY - 560, 384 - 540) * 180 / .pi + 360
        arc(path, cx: 540, cy: 560, r: 228, from: start, to: 450)
        path.addLine(to: CGPoint(x: 268, y: 788))
        path.closeSubpath()
        // The counter: a bubble with its own square tail.
        path.move(to: CGPoint(x: 540, y: 474))
        arc(path, cx: 540, cy: 570, r: 96, from: 270, to: 450)
        path.addLine(to: CGPoint(x: 444, y: 666))
        path.addLine(to: CGPoint(x: 444, y: 570))
        arc(path, cx: 540, cy: 570, r: 96, from: 180, to: 270)
        path.closeSubpath()
        return path
    }
}

/// The accent macOS uses for the sidebar, selection and prominent buttons. The same values as
/// Theme.accentFill: deep enough to carry white labels.
func writeAccentCatalog(to catalog: URL) throws {
    let set = catalog.appendingPathComponent("AccentColor.colorset")
    try? FileManager.default.removeItem(at: catalog)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try Data(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
    func colour(_ r: String, _ g: String, _ b: String) -> String {
        #"{ "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "\#(r)", "green" : "\#(g)", "blue" : "\#(b)" } }"#
    }
    let json = """
    {
      "colors" : [
        { "idiom" : "universal", "color" : \(colour("0.043", "0.498", "0.651")) },
        { "idiom" : "universal", "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "color" : \(colour("0.086", "0.561", "0.714")) }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try Data(json.utf8).write(to: set.appendingPathComponent("Contents.json"))
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--accent" {
    try writeAccentCatalog(to: URL(fileURLWithPath: arguments[2]))
} else if arguments.count == 4, arguments[1] == "--png", let size = Int(arguments[3]) {
    try writePNG(to: URL(fileURLWithPath: arguments[2]), size: size)
} else if arguments.count == 2 {
    try writeIconBundle(to: URL(fileURLWithPath: arguments[1]))
} else {
    FileHandle.standardError.write(Data("usage: make-icon <AppIcon.icon> | --png <file.png> <size>\n".utf8))
    exit(2)
}
