import AppKit
import CoworkKit
import SwiftUI

// The app's surfaces and parts, with the exact values of the design: deep graphite in dark,
// clean white in light, opaque everywhere so the desktop never tints the window.

extension Theme {
    private static func pair(_ name: String, _ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        func ns(_ hex: UInt32, _ alpha: Double) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }

    enum Surface {
        /// The window's content.
        static let window = Theme.pair("bcWindow", 0xFFFFFF, 0x1E1E20)
        static let sidebar = Theme.pair("bcSidebar", 0xF0F1F3, 0x262628)
        static let bar = Theme.pair("bcBar", 0xFBFBFC, 0x212123)
        /// A group of rows, a card, a well.
        static let group = Theme.pair("bcGroup", 0xF5F5F7, 0x262628)
        /// A control's own face: a secondary button, the selected segment.
        static let control = Theme.pair("bcControl", 0xFFFFFF, 0x3A3A3D)
        static let controlEdge = Theme.pair("bcControlEdge", 0x000000, 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.06)
        /// Quiet fill: tracks, user bubbles, toolbar capsules.
        static let fill = Theme.pair("bcFill", 0x000000, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.07)
        /// Neutral selection.
        static let selection = Theme.pair("bcSelection", 0x000000, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
        static let line = Theme.pair("bcLine", 0x000000, 0xFFFFFF, lightAlpha: 0.085, darkAlpha: 0.085)
        static let primary = Theme.pair("bcText", 0x1D1D1F, 0xF2F2F4)
        static let secondary = Theme.pair("bcText2", 0x6E6E73, 0x98989E)
        static let tertiary = Theme.pair("bcText3", 0xAEAEB2, 0x5E5E63)
        /// Text on the bright accent.
        static let onAccent = Theme.pair("bcOnAccent", 0x03222C, 0x03222C)
    }
}

// MARK: - Buttons

/// The one thing to do next: the bright accent with dark text.
struct PrimaryButton: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.Surface.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(Theme.accentBright, in: .rect(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(.rect)
    }
}

/// Everything beside it: a quiet raised face.
struct SecondaryButton: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.Surface.primary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(configuration.isPressed ? Theme.Surface.selection : Theme.Surface.control,
                        in: .rect(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.Surface.controlEdge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(.rect)
    }
}

/// A word that acts: Not Now, Show in Finder.
struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.Surface.secondary)
            .padding(.horizontal, 4)
            .frame(height: 26)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(.rect)
    }
}

/// A link in the accent: "Usage", "All".
struct LinkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == PrimaryButton { static var primary: PrimaryButton { PrimaryButton() } }
extension ButtonStyle where Self == SecondaryButton { static var secondary: SecondaryButton { SecondaryButton() } }
extension ButtonStyle where Self == QuietButton { static var quiet: QuietButton { QuietButton() } }
extension ButtonStyle where Self == LinkButton { static var accentLink: LinkButton { LinkButton() } }

// MARK: - Segmented

/// A segmented control with a neutral selected segment: a raised face, never the accent.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var symbols = false
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if symbols { Image(systemName: option.label).font(.system(size: 13)) }
                        else { Text(option.label).font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(on ? Theme.Surface.primary : Theme.Surface.primary.opacity(0.75))
                    .padding(.horizontal, symbols ? 9 : 12)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Surface.control)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.Surface.controlEdge, lineWidth: 0.5))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(symbols ? "" : option.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.Surface.fill, in: .rect(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

// MARK: - Page structure

/// Page title and the one sentence under it.
struct PageTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3)
                .foregroundStyle(Theme.Surface.primary)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The label over a group: 13 semibold, 26 above, 8 below, with an optional link.
struct SectionLabel: View {
    let title: String
    var detail: String?
    var link: String?
    var action: (() -> Void)?
    var top: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Surface.primary)
            if let detail { Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Surface.secondary) }
            Spacer(minLength: 8)
            if let link, let action { Button(link, action: action).buttonStyle(.accentLink) }
        }
        .padding(.horizontal, 4)
        .padding(.top, top)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Rows on the group fill with hairlines inset to where the text starts.
struct Card<Content: View>: View {
    var inset: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(Theme.Surface.line).frame(height: 0.5).padding(.leading, inset)
                    }
                    row
                }
            }
        }
        .background(Theme.Surface.group, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// One row: optional leading icon, title over a detail line, then whatever sits at the end.
struct Row<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = Theme.Surface.secondary
    var detailLines = 1
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Surface.primary).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(detailColor).lineLimit(detailLines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

extension Row where Leading == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color = Theme.Surface.secondary, detailLines: Int = 1,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, detail: detail, detailColor: detailColor, detailLines: detailLines,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

extension Row where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A value at the end of a row.
struct RowValue: View {
    let text: String
    var attention = false
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: attention ? .semibold : .regular))
            .foregroundStyle(attention ? Theme.attention : Theme.Surface.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Surface.tertiary).accessibilityHidden(true)
    }
}

/// A 16pt symbol in a row's leading slot.
struct RowSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 14)).foregroundStyle(Theme.Surface.secondary)
            .frame(width: 18).accessibilityHidden(true)
    }
}

/// A 4pt capsule meter with an optional forecast tick.
struct ThinMeter: View {
    let value: Double
    var mark: Double?
    var color: Color = Theme.accentBright

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.fill)
                Capsule().fill(color).frame(width: max(0, geometry.size.width * min(1, value)))
                if let mark {
                    Rectangle().fill(Theme.Surface.secondary).frame(width: 1.5, height: 10)
                        .offset(x: geometry.size.width * min(1, mark) - 0.75)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A figure in SF Rounded with its unit small and grey.
struct Figure: View {
    let value: String
    var unit: String?
    var size: CGFloat = 24
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.Surface.primary)
            if let unit {
                Text(unit).font(.system(size: size * 0.58, weight: .medium)).foregroundStyle(Theme.Surface.secondary)
            }
        }
        .contentTransition(.numericText())
    }
}

/// A page's scroll area: 28pt sides, the window surface behind.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 1080
    var centered = false
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Surface.window)
    }
}

/// A search field look-alike that opens ⌘K, the one way to search and ask.
struct SearchPill: View {
    var prompt = "Search or ask"
    var width: CGFloat = 200
    let action: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5))
            Text(prompt).font(.system(size: 13))
            Spacer(minLength: 4)
            Text("⌘K").font(.system(size: 11)).foregroundStyle(Theme.Surface.tertiary)
        }
        .foregroundStyle(Theme.Surface.secondary)
        .padding(.horizontal, 12)
        .frame(width: width, height: 30)
        .background(Theme.Surface.fill, in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: action)
        .help("Search or ask (⌘K)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityLabel("Search or ask")
    }
}
