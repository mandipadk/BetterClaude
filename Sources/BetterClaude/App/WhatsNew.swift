import AppKit
import SwiftUI

/// What changed, shown once after an update. Written for people, per release, rather than
/// taken from commit messages.
enum ReleaseHighlights {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let byVersion: [String: [Item]] = [
        "0.2.0": [
            Item(symbol: "rectangle.stack", title: "Every Claude, in one window",
                 detail: "Conversations from Claude, its Parallex copies, Claude Code and the Code tab, in one timeline with a reader beside it."),
            Item(symbol: "arrow.right.circle", title: "Continue anywhere, and undo it",
                 detail: "Carry a conversation to another Claude or into Claude Code, fork one from any message, and take either back from History."),
            Item(symbol: "archivebox", title: "Kept",
                 detail: "Claude Code deletes conversations after 30 days. Better Claude now keeps a copy first."),
            Item(symbol: "internaldrive", title: "Storage and Memory",
                 detail: "See what Claude keeps on disk and free what's safe to, and read what it remembers about every project."),
        ],
    ]

    static func items(for version: String) -> [Item]? { byVersion[version] }
}

struct WhatsNewSheet: View {
    let version: String
    let onClose: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text("What's new in Better Claude").font(Theme.Font.display)
                Text("Version \(version)").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array((ReleaseHighlights.items(for: version) ?? []).enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Theme.Font.headline)
                            Text(item.detail)
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 8)
                    .animation(Theme.Motion.smooth.delay(0.12 + 0.06 * Double(index)), value: shown)
                }
            }
            .frame(width: 400)
            Spacer(minLength: 0)
            Button("Continue", action: onClose)
                .prominentAction()
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 500, height: 560)
        .background(WindowGlassBackground(material: .sidebar))
        .tint(Theme.accent)
        .onAppear { shown = true }
    }
}
