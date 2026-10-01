import AppKit
import CoworkKit
import SwiftUI

// MARK: - Buttons

/// The ⋯ menu beside a page's primary action, drawn by the system as a bordered button.
struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }
}

// MARK: - Sections

/// A titled region of a detail page. No card: a label, a hairline, space.
struct DetailSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.section)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(.vertical, Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// A toggle with a title and an explanation underneath.
struct ExplainedToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.l)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
    }
}

/// A label on the left and its value beside it: how this app shows facts, instead of joining
/// them into one line.
struct FactRow: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(Theme.Font.callout)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An explanation for an empty place: a headline, one sentence, and optionally the thing to
/// do about it.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(Theme.Font.title)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // A floor as well as a ceiling. Asked for its minimum at zero width, text that
                // is fixed-size vertically wraps a character per line and reports a height of
                // thousands of points, and the whole window shifts up to make room for it.
                .frame(minWidth: 220, maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Keys

/// A keyboard shortcut drawn as keycaps, with a visible gap between keys.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 3)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: 4))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Icons

/// App icons are expensive to fetch; cache them per path.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let imageExtensions: Set<String> = ["icns", "png", "jpg", "jpeg", "tiff", "heic"]
        let icon: NSImage
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            icon = image
        } else {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// The icon of a Claude install: its own app's icon, so a Parallex copy looks the way it
/// does in the Dock. Claude Code has no app, so it gets a drawn tile in the same proportions
/// as a macOS icon.
struct InstallIcon: View {
    let install: Install
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url = install.iconURL {
                Image(nsImage: IconCache.icon(for: url))
                    .resizable()
                    .interpolation(.high)
            } else {
                GlyphTile(systemImage: glyph, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var glyph: String {
        switch install.kind {
        case .claudeCode: return "terminal.fill"
        case .external(.claudeWeb): return "globe"
        case .external(.codex): return "chevron.left.forwardslash.chevron.right"
        case .external(.otherMac): return "laptopcomputer"
        default: return "questionmark"
        }
    }
}

/// A plain tile on the macOS icon grid (824 of 1024, continuous corners) with a symbol on it,
/// for things that have no icon of their own.
struct GlyphTile: View {
    let systemImage: String
    var size: CGFloat = 32

    var body: some View {
        let plate = size * 824 / 1024
        RoundedRectangle(cornerRadius: plate * 0.225, style: .continuous)
            .fill(Color(nsColor: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)))
            .overlay {
                RoundedRectangle(cornerRadius: plate * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: max(0.5, size / 64))
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: plate * 0.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: plate, height: plate)
            .frame(width: size, height: size)
    }
}

// MARK: - Brand mark

/// Better Claude's mark: a heavy lowercase b whose square corner is a speech bubble's tail,
/// with a smaller speech bubble for its counter. The same geometry as the app icon
/// (Scripts/make-icon.swift).
struct BMark: View {
    var size: CGFloat = 17
    var tint: Color = Theme.accentBright

    var body: some View {
        BMarkShape()
            .fill(tint, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct BMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The glyph's box on the icon's 1024 grid, fitted to the rect.
        let box = CGRect(x: 268, y: 242, width: 500, height: 546)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * scale, dy = rect.midY - box.midY * scale
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale + dx, y: y * scale + dy) }
        var path = Path()
        func arc(_ cx: Double, _ cy: Double, _ r: Double, _ from: Double, _ to: Double) {
            let steps = 32
            for i in 1...steps {
                let t = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
                path.addLine(to: p(cx + r * cos(t), cy + r * sin(t)))
            }
        }
        path.move(to: p(268, 300))
        arc(326, 300, 58, 180, 360)
        let joinY = 560 - (228.0 * 228 - 156 * 156).squareRoot()
        path.addLine(to: p(384, joinY))
        arc(540, 560, 228, atan2(joinY - 560, 384 - 540) * 180 / .pi + 360, 450)
        path.addLine(to: p(268, 788))
        path.closeSubpath()
        path.move(to: p(540, 474))
        arc(540, 570, 96, 270, 450)
        path.addLine(to: p(444, 666))
        path.addLine(to: p(444, 570))
        arc(540, 570, 96, 180, 270)
        path.closeSubpath()
        return path
    }
}

// MARK: - Formatting

extension String {
    /// "Yesterday" becomes "yesterday" mid-sentence; weekdays, "12 Sep" and "14:22" stay as
    /// they are.
    var lowercasedIfWordLocal: String {
        self == "Yesterday" || self == "Today" ? lowercased() : self
    }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    /// "14:22" today, "Yesterday", a weekday this week, "12 Sep" this year, "12 Sep 2025".
    var listStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// `claude-opus-4-8[1m]` → `Opus 4.8`. Unrecognised identifiers pass through unchanged.
func humanModelName(_ raw: String) -> String {
    var name = raw
    if let bracket = name.firstIndex(of: "[") { name = String(name[name.startIndex..<bracket]) }
    guard name.hasPrefix("claude-") else { return raw }
    let parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
    guard let family = parts.first else { return raw }
    let version = parts.dropFirst().joined(separator: ".")
    return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
}
