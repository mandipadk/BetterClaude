import AppKit
import CoworkKit
import SwiftUI

/// Reads a conversation without leaving the app.
///
/// Deliberately a typographic transcript rather than chat bubbles: a bubble is a rounded
/// container around every message, which is the card pattern repeated a hundred times down
/// the page. Speaker changes are carried by a small label and the space around it, which is
/// how a printed interview does it and how it stays readable at length.
struct ConversationView: View {
    let title: String
    let subtitle: String
    let messages: [MessageText]
    let onClose: () -> Void
    let onExport: () -> Void

    @State private var query = ""

    private var filtered: [MessageText] {
        guard !query.isEmpty else { return messages }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if filtered.isEmpty {
                Empty(headline: "Nothing matches",
                      detail: "No message in this conversation contains “\(query)”.")
            } else {
                transcript
            }
            Hairline()
            actionBar
        }
    }

    /// Every other pane ends in a bar; without one the transcript ran into the window edge
    /// and the pane read as unfinished next to its siblings.
    private var actionBar: some View {
        HStack(spacing: Design.Space.s) {
            Text("\(filtered.count) message\(filtered.count == 1 ? "" : "s")"
                 + (query.isEmpty ? "" : " matching"))
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
            Spacer()
            Button("Export", action: onExport)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, Design.Space.s)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            Button(action: onClose) {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("All conversations")
                }
                .foregroundStyle(Design.Palette.secondary)
                .font(Design.Typography.body)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all conversations")

            Spacer(minLength: Design.Space.l)
            SearchField(text: $query)
                .frame(width: 190)
        }
        .padding(.leading, Design.Space.gutter)
        .padding(.trailing, Design.Space.m)
        .padding(.top, WindowMetrics.titlebarInset + Design.Space.m + 3)
        .padding(.bottom, Design.Space.m)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Design.Typography.title)
                        .foregroundStyle(Design.Palette.primary)
                    Text(subtitle)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                }
                .padding(.top, Design.Space.l)
                .padding(.bottom, Design.Space.l)

                ForEach(filtered) { message in
                    MessageBlock(message: message, highlight: query)
                }
                Color.clear.frame(height: Design.Space.xxl)
            }
            .padding(.horizontal, Design.Space.xl)
            // A measured line length. Full-window prose is unreadable however good the type
            // is; this has to sit outside the padding or the outer frame overrides it.
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .fadingBottomEdge(64)
    }
}

private struct MessageBlock: View {
    let message: MessageText
    let highlight: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.s) {
                Text(speaker)
                    .font(Design.Typography.label)
                    .tracking(0.6)
                    .foregroundStyle(message.role == .user ? Design.Palette.accent : Design.Palette.muted)
                if let stamp = message.timestamp {
                    Text(stamp.formatted(date: .omitted, time: .shortened))
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(marked(text))
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.primary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    Text(text)
                        .font(Design.Typography.mono)
                        .foregroundStyle(Design.Palette.secondary)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Design.Space.m)
                        .overlay(alignment: .leading) {
                            // A rule rather than a filled block: a shaded code panel is a card.
                            Rectangle()
                                .fill(Design.Palette.separator)
                                .frame(width: 2)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Design.Space.l)
    }

    private var speaker: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Claude"
        case .system: return "System"
        case .tool: return "Tool"
        case .unknown: return "—"
        }
    }

    private enum Segment { case prose(String), code(String) }

    /// Splits on fenced code blocks only. Full Markdown rendering would mean shipping a
    /// parser for content this view does not own; fences are the one structure that becomes
    /// unreadable without handling.
    private var segments: [Segment] {
        let parts = message.text.components(separatedBy: "```")
        guard parts.count > 1 else { return [.prose(message.text)] }
        return parts.enumerated().compactMap { index, part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if index.isMultiple(of: 2) { return .prose(trimmed) }
            // Drop the language tag on the fence's first line.
            let body = trimmed.contains("\n") && !trimmed.hasPrefix("\n")
                ? String(trimmed.drop(while: { $0 != "\n" })).trimmingCharacters(in: .newlines)
                : trimmed
            return .code(body)
        }
    }

    private func marked(_ text: String) -> AttributedString {
        // Inline Markdown only — bold, italic, code spans and links. Block structure is left
        // alone because `.inlineOnlyPreservingWhitespace` is the one option that keeps the
        // paragraph breaks this transcript relies on.
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        guard !highlight.isEmpty else { return attributed }
        var cursor = attributed.startIndex
        while cursor < attributed.endIndex,
              let found = attributed[cursor...].range(of: highlight, options: .caseInsensitive) {
            attributed[found].font = Design.Typography.body.weight(.semibold)
            attributed[found].foregroundColor = Design.Palette.accent
            cursor = found.upperBound
        }
        return attributed
    }
}
