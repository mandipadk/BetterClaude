import CoworkKit
import SwiftUI

/// Results from searching every conversation on the machine.
///
/// A hit is a conversation, not a message: people look for "the chat where we worked out the
/// migration", and a flat list of matching lines from thirty conversations answers a
/// different question than the one being asked. Matching excerpts sit under the title as
/// evidence for why the conversation is here.
struct SearchResults: View {
    let model: AppModel

    var body: some View {
        if model.isIndexing && model.globalHits.isEmpty {
            VStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading every conversation once…")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.globalHits.isEmpty {
            Empty(headline: "No matches anywhere",
                  detail: "Nothing in \(model.indexedConversations) conversations matches “\(model.globalQuery)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.globalHits.enumerated()), id: \.element.id) { index, hit in
                        HitRow(hit: hit) { model.reveal(hit) }
                        if index < model.globalHits.count - 1 { Hairline() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .fadingBottomEdge(56)
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Text(hit.conversationTitle)
                        .font(Design.Typography.bodyEmphasis)
                        .foregroundStyle(Design.Palette.primary)
                        .lineLimit(1)
                    Text(hit.location.container)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: Design.Space.m)
                    Text("\(hit.totalMatches) match\(hit.totalMatches == 1 ? "" : "es")")
                        .font(Design.Typography.numeric)
                        .foregroundStyle(Design.Palette.muted)
                    Text(hit.lastActivity.compactStamp)
                        .font(Design.Typography.numeric)
                        .foregroundStyle(Design.Palette.secondary)
                        .frame(width: 74, alignment: .trailing)
                }
                ForEach(hit.excerpts) { excerpt in
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                        Text(excerpt.role == .user ? "You" : "Claude")
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Palette.muted)
                            .frame(width: 40, alignment: .leading)
                        Text(highlighted(excerpt))
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Palette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, Design.Space.gutter)
            .padding(.vertical, Design.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Design.Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(hit.conversationTitle), \(hit.totalMatches) matches")
    }

    /// Matches are marked with weight and full-strength ink rather than a highlight fill —
    /// a coloured background behind running text would be a second accent surface.
    private func highlighted(_ excerpt: SearchHit.Excerpt) -> AttributedString {
        var attributed = AttributedString(excerpt.text)
        for range in excerpt.ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].font = Design.Typography.caption.weight(.semibold)
            attributed[lower..<upper].foregroundColor = Design.Palette.primary
        }
        return attributed
    }
}
