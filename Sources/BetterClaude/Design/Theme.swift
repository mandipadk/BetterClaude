import AppKit
import SwiftUI

/// Better Claude's design tokens, in the same language as Parallex: one accent color for the
/// thing to do next, selection, and the mark; native neutrals and materials for everything
/// else, so the app reads as part of macOS. Install colors are data — small marks, never
/// chrome.
enum Theme {

    // MARK: Accent

    /// The accent is jade. The other candidates stay for comparison in debug builds. Each is
    /// tuned per appearance: deep enough in light mode to
    /// carry white text at 4.5:1 or better, brighter in dark mode where it sits on graphite.
    enum Accent: String, CaseIterable {
        case jade, teal, cobalt

        var light: NSColor {
            switch self {
            case .jade: return NSColor(srgbRed: 0.043, green: 0.490, blue: 0.349, alpha: 1)   // #0B7D59
            case .teal: return NSColor(srgbRed: 0.043, green: 0.498, blue: 0.525, alpha: 1)   // #0B7F86
            case .cobalt: return NSColor(srgbRed: 0.165, green: 0.357, blue: 0.843, alpha: 1) // #2A5BD7
            }
        }

        var dark: NSColor {
            switch self {
            case .jade: return NSColor(srgbRed: 0.180, green: 0.698, blue: 0.494, alpha: 1)   // #2EB27E
            case .teal: return NSColor(srgbRed: 0.137, green: 0.667, blue: 0.698, alpha: 1)   // #23AAB2
            case .cobalt: return NSColor(srgbRed: 0.341, green: 0.522, blue: 1.0, alpha: 1)   // #5785FF
            }
        }
    }

    /// The accent in use. Debug builds can try another with `BC_ACCENT=teal` and friends.
    static let accentChoice: Accent = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["BC_ACCENT"], let choice = Accent(rawValue: raw) {
            return choice
        }
        #endif
        return .jade
    }()

    static let accentNS = NSColor(name: "BetterClaudeAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? accentChoice.dark : accentChoice.light
    }
    static let accent = Color(nsColor: accentNS)

    /// The accent as a fill under white text. In light mode it is the accent itself; in dark
    /// mode the accent is bright enough to glow on graphite, which leaves white labels on it
    /// at 2.7:1, so filled buttons use a deeper jade that holds 3.7:1 for their bold labels.
    static let accentFill = Color(nsColor: NSColor(name: "BetterClaudeAccentFill") { appearance in
        guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return accentChoice.light }
        return accentChoice == .jade
            ? NSColor(srgbRed: 0.133, green: 0.596, blue: 0.416, alpha: 1)   // #22986A
            : accentChoice.dark.blended(withFraction: 0.25, of: .black) ?? accentChoice.dark
    })

    static let attention = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
    static let hairline = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

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
