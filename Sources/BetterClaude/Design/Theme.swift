import AppKit
import SwiftUI

/// Better Claude's design tokens: one accent, used sparingly (selection, the one thing to do
/// next, links, the app's own data); native neutrals and materials for everything else, so
/// the app reads as part of macOS. Status is said in words, never with tinted panels. Install
/// colours are data, small marks, never chrome.
enum Theme {

    // MARK: Accent

    /// The accent is Lagoon, a cyan from the far side of the colour wheel from Claude's clay,
    /// so the app's own actions never blend into the install icons around them. It has three
    /// jobs, each with its own value per appearance.
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// Ink: links, selected text and symbols. Readable at 4.5:1 or better on the window.
    static let accentNS = dynamic("BetterClaudeAccent",
                                  light: NSColor(srgbRed: 0.000, green: 0.471, blue: 0.604, alpha: 1),   // #00789A
                                  dark: NSColor(srgbRed: 0.310, green: 0.827, blue: 0.961, alpha: 1))    // #4FD3F5
    static let accent = Color(nsColor: accentNS)

    /// Fill: the one prominent button and switches, which carry white labels. Deep enough for
    /// 4.6:1 in light mode and 3.7:1 in dark, the level of the system's own blue.
    static let accentFillNS = dynamic("BetterClaudeAccentFill",
                                      light: NSColor(srgbRed: 0.043, green: 0.498, blue: 0.651, alpha: 1),  // #0B7FA6
                                      dark: NSColor(srgbRed: 0.086, green: 0.561, blue: 0.714, alpha: 1))   // #168FB6
    static let accentFill = Color(nsColor: accentFillNS)

    /// Bright: meters, charts and the mark, where nothing sits on top of it.
    static let accentBright = Color(nsColor: dynamic("BetterClaudeAccentBright",
                                                     light: NSColor(srgbRed: 0.114, green: 0.714, blue: 0.878, alpha: 1),   // #1DB6E0
                                                     dark: NSColor(srgbRed: 0.208, green: 0.784, blue: 0.941, alpha: 1)))   // #35C8F0

    static let attention = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
    static let hairline = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    /// The grouped fill under content: rows, wells, tiles.
    static let groupFill = Color(nsColor: .quaternarySystemFill)

    // MARK: Type
    // SF Pro throughout; the Display optical size takes over at 20pt and up.

    enum Font {
        static let hero = SwiftUI.Font.system(size: 34, weight: .bold)
        static let display = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// Section titles on a detail page.
        static let section = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        /// Reading size for a conversation: a touch larger than UI text, set for paragraphs.
        static let reading = SwiftUI.Font.system(size: 14)
        /// A limit's percentage: the one place the app uses SF Rounded, so a figure reads as one.
        static let figure = SwiftUI.Font.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()
        /// Code, only ever inside a contained surface.
        static let code = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    // MARK: Layout

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        static let control: CGFloat = 7
        static let tile: CGFloat = 10
        /// A group of rows on a page.
        static let group: CGFloat = 12
        static let panel: CGFloat = 14
    }

    // MARK: Motion
    // Springs for anything that moves, short ease-outs for fades. Views check Reduce Motion
    // and fall back to opacity.

    enum Motion {
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.88)
        static let fade = Animation.easeOut(duration: 0.18)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
