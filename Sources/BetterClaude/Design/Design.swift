import AppKit
import SwiftUI

/// The whole visual vocabulary of the app, in one file.
///
/// Constraints this encodes, deliberately:
///
/// - **Two colours.** One warm clay accent for the single most important action on screen,
///   and one neutral ink ramp for everything else. Anything that needs to stand out earns
///   it through weight, size, or space — not through a new hue.
/// - **No cards.** Grouping comes from whitespace and hairline rules. Nested rounded
///   rectangles read as a form, not as an application.
/// - **No gradients, no glows, no emoji.** Depth comes from the system's own materials.
/// - **Typography carries hierarchy.** Six sizes, three weights, and nothing else.
enum Design {

    // MARK: - Colour

    enum Palette {
        /// The accent. Used for exactly one thing per screen: the action the user came here
        /// to take. A warm clay rather than the system blue, which is both overused and
        /// carries no meaning here.
        static let accent = Color(light: NSColor(srgbRed: 0.729, green: 0.337, blue: 0.192, alpha: 1),
                                  dark: NSColor(srgbRed: 0.851, green: 0.475, blue: 0.349, alpha: 1))

        /// Pressed / hovered accent.
        static let accentPressed = Color(light: NSColor(srgbRed: 0.639, green: 0.290, blue: 0.161, alpha: 1),
                                         dark: NSColor(srgbRed: 0.780, green: 0.412, blue: 0.290, alpha: 1))

        /// The neutral ramp, two values deep and no deeper.
        ///
        /// `tertiaryLabelColor` resolves to roughly 2.3:1 against this app's background,
        /// which is below any usable reading threshold — using it for metadata produced a
        /// cliff between "legible" and "invisible" rather than a hierarchy. Supporting text
        /// therefore stops at `secondary`, and `faint` is reserved for things that are not
        /// text: placeholder glyphs, unselected control rings, rules.
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color(light: NSColor(white: 0.32, alpha: 1),
                                     dark: NSColor(white: 0.72, alpha: 1))
        /// A genuine third step — recessive but still clearing 4.5:1 everywhere it is drawn.
        ///
        /// This tier was set to "~4:1" on the theory that it only carried labels. It does
        /// not: it sets running sentences in the transfer sheet, including the one stating
        /// that credentials are never exported and the detail on a failed precondition. At
        /// 0.52 dark it measured 4.494:1 on the window background and 4.066:1 on `raised`,
        /// which every sheet uses — so the tier failed exactly where it carried prose. 0.565
        /// gives 5.02:1 and 4.55:1. Any future change here must be checked against `raised`,
        /// not just `background`; `raised` is the darker surface and the binding constraint.
        static let muted = Color(light: NSColor(white: 0.44, alpha: 1),
                                 dark: NSColor(white: 0.565, alpha: 1))
        /// Non-text only: placeholder glyphs and rules.
        static let faint = Color(nsColor: .tertiaryLabelColor)
        /// Unselected control strokes. An unchecked box is an affordance, not decoration, so
        /// it needs to clear 3:1 against its surface rather than sitting at `faint`.
        static let controlStroke = Color(light: NSColor(white: 0.55, alpha: 1),
                                         dark: NSColor(white: 0.48, alpha: 1))
        /// Ink that sits *on* the accent fill.
        ///
        /// The dark-appearance accent is a light clay, so white on it measures 3.1:1 — the
        /// least readable text in the app, on its most important control. Near-black on the
        /// same fill measures about 5.5:1.
        static let onAccent = Color(light: NSColor.white,
                                    dark: NSColor(srgbRed: 0.11, green: 0.09, blue: 0.08, alpha: 1))

        static let separator = Color(nsColor: .separatorColor)

        /// The single surface colour for the whole window. Deliberately used for the
        /// titlebar too: the default toolbar material is a cool grey that reads as blue and,
        /// being empty and full-width, was the largest coloured area on screen.
        static let background = Color(nsColor: .textBackgroundColor)

        /// Raised one measurable step above `background` so a sheet reads as being in front
        /// of the window rather than continuous with it.
        static let raised = Color(light: NSColor(white: 1.0, alpha: 1),
                                  dark: NSColor(white: 0.15, alpha: 1))

        /// Selection fill. Deliberately a low-alpha wash of the accent rather than a solid
        /// block, so a selected row still reads as text first.
        static let selection = accent.opacity(0.30)
        static let hover = Color(nsColor: .labelColor).opacity(0.05)

        /// The one place a third hue is permitted: a blocking problem. Muted, never pure red.
        static let critical = Color(light: NSColor(srgbRed: 0.647, green: 0.208, blue: 0.169, alpha: 1),
                                    dark: NSColor(srgbRed: 0.831, green: 0.400, blue: 0.353, alpha: 1))
    }

    // MARK: - Type

    enum Typography {
        /// Window-level heading.
        static let title = Font.system(size: 20, weight: .semibold)
        /// Section or sheet heading.
        static let heading = Font.system(size: 15, weight: .semibold)
        /// Primary row content.
        static let body = Font.system(size: 13, weight: .regular)
        /// Primary row content that needs slight emphasis.
        static let bodyEmphasis = Font.system(size: 13, weight: .medium)
        /// Supporting text under a row.
        static let caption = Font.system(size: 11, weight: .regular)
        /// Sidebar and column headings. Always paired with `.secondary` and tracking.
        static let label = Font.system(size: 10, weight: .semibold)
        /// Numbers that sit in a column and must not jitter.
        static let numeric = Font.system(size: 11, weight: .regular).monospacedDigit()
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - Metrics

    enum Space {
        static let hairline: CGFloat = 1
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32

        /// Horizontal inset shared by every scrolling surface, so content lines up down the
        /// whole window regardless of which pane it is in.
        static let gutter: CGFloat = 16
        static let rowHeight: CGFloat = 32
        static let sidebarRowHeight: CGFloat = 34
        static let corner: CGFloat = 6
    }

    enum Duration {
        /// Short enough to feel like a state change rather than an animation.
        static let quick: TimeInterval = 0.12
    }
}

extension Color {
    /// A colour that resolves per appearance without threading `@Environment` through every
    /// view. `NSColor(name:dynamicProvider:)` is the only way to get this for custom values.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .some(.darkAqua): return dark
            default: return light
            }
        })
    }
}

// MARK: - Primitives

/// A small uppercase heading. The only place tracking is used in the app.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(0.6)
            .foregroundStyle(Design.Palette.muted)
    }
}

/// A one-pixel rule that stays one pixel on Retina.
struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Design.Palette.separator)
            .frame(height: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
            .padding(.leading, inset)
    }
}

/// The single accented action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.bodyEmphasis)
            .foregroundStyle(isEnabled ? Design.Palette.onAccent : Design.Palette.controlStroke)
            .padding(.horizontal, Design.Space.m)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .strokeBorder(isEnabled ? .clear : Design.Palette.controlStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    /// A disabled primary action becomes an outline rather than a faded accent. A dim
    /// tinted fill reads as "broken"; a near-invisible grey fill reads as a failed render.
    /// An outline reads as the button it will become.
    private func fill(pressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        return pressed ? Design.Palette.accentPressed : Design.Palette.accent
    }
}

/// Everything that is not the primary action. Text-weight, no fill, no border until hovered.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.body)
            // One disabled recipe across both button styles: a faded label reads as a
            // rendering failure, where a control-stroke label reads as "not yet".
            .foregroundStyle(isEnabled ? Design.Palette.secondary : Design.Palette.controlStroke)
            .padding(.horizontal, Design.Space.m)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? Design.Palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// A status mark. A glyph rather than a coloured dot, so it survives greyscale and reads
/// without a legend.
struct StatusMark: View {
    enum Kind { case ok, blocked, warning }
    let kind: Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: kind == .warning ? 12 : 11, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 14, alignment: .leading)
            // Without this the mark is decorative to VoiceOver, so a passed and a failed
            // precondition — the entire point of the review step — announce identically.
            .accessibilityLabel(spoken)
    }

    private var spoken: String {
        switch kind {
        case .ok: return "passed"
        case .blocked: return "blocked"
        case .warning: return "warning"
        }
    }

    private var symbol: String {
        switch kind {
        case .ok: return "checkmark"
        case .blocked: return "xmark"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .ok: return Design.Palette.muted
        case .blocked: return Design.Palette.critical
        // Deliberately not the accent: the accent means "this is the action you came for",
        // and a warning is its opposite. Urgency here comes from the glyph's shape, from
        // being first on the screen, and from the heading above it.
        case .warning: return Design.Palette.secondary
        }
    }
}

extension View {
    /// Standard horizontal inset for content inside a scrolling pane.
    func gutter() -> some View {
        padding(.horizontal, Design.Space.gutter)
    }
}

extension Int64 {
    var fileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Date {
    /// Short, human, and stable in width: "12 Mar", "12 Mar 2025", "14:22" for today.
    var compactStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(.dateTime.hour().minute())
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// A subordinate heading inside a section. Sentence case rather than the uppercase
/// `SectionLabel`, so the two levels are distinguishable without a size change.
struct SubHead: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.label)
            .tracking(0.6)
            .foregroundStyle(Design.Palette.muted)
    }
}

/// Fades content out at the bottom of a scrolling region, so a clipped row reads as "there
/// is more" rather than as a rendering failure.
///
/// The band must be taller than one row: a ramp shorter than the row height bisects glyphs
/// instead of fading whole rows, which looks like a different bug rather than none.
struct BottomFade: ViewModifier {
    var height: CGFloat = 48

    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0),
                        .init(color: .black, location: 1)],
                startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .bottom) {
                // `.destinationOut` erases where the source is opaque, so the opaque end of
                // this gradient must be at the *bottom* — the edge being faded away.
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

extension View {
    /// `height` is required on purpose: it must exceed the row pitch of whatever is being
    /// faded, and a default cannot know that.
    func fadingBottomEdge(_ height: CGFloat) -> some View {
        modifier(BottomFade(height: height))
    }
}

extension String {
    /// `/Users/me/Library/…` → `~/Library/…`.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        guard hasPrefix(home) else { return self }
        let tail = dropFirst(home.count)
        return tail.isEmpty ? "Home folder" : "~" + tail
    }
}

/// A checkbox drawn by the app rather than AppKit.
///
/// The system control carries its own intrinsic leading inset, which put option groups on
/// different left edges from the section labels heading them, and its unselected box renders
/// at roughly 1.35:1 — below the threshold at which an affordance reads as present at all.
struct Checkbox: View {
    let title: String
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: Design.Space.s) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? Design.Palette.accent : .clear)
                    .frame(width: 13, height: 13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(isOn ? .clear : Design.Palette.controlStroke, lineWidth: 1)
                    )
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Design.Palette.onAccent)
                        }
                    }
                Text(title)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// One option in a mutually exclusive group, matching ``Checkbox`` in leading and contrast.
struct RadioOption<Value: Hashable>: View {
    let title: String
    let value: Value
    @Binding var selection: Value

    private var isSelected: Bool { selection == value }

    var body: some View {
        Button { selection = value } label: {
            HStack(spacing: Design.Space.s) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.controlStroke)
                    .frame(width: 13)
                Text(title)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A show/hide control that looks like one.
struct DisclosureToggle: View {
    let expandedTitle: String
    let collapsedTitle: String
    @Binding var isExpanded: Bool
    var leadingMark: StatusMark.Kind?

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: Design.Duration.quick)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Design.Space.s) {
                if let leadingMark { StatusMark(kind: leadingMark) }
                Text(isExpanded ? expandedTitle : collapsedTitle)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Palette.muted)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Fades a horizontally scrolling row at its trailing edge, so a filter list that runs past
/// the window reads as continuing rather than as ending where the window does.
struct TrailingFade: ViewModifier {
    var width: CGFloat = 32

    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

extension View {
    func fadingTrailingEdge(_ width: CGFloat = 32) -> some View {
        modifier(TrailingFade(width: width))
    }
}
