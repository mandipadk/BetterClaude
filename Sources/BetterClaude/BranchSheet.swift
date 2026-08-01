import CoworkKit
import SwiftUI

/// Fork a conversation at a chosen message.
///
/// The whole decision is a single consequence — this many messages come with you, this many
/// stay behind — so the sheet is built to make that consequence impossible to miss twice:
/// once as a sentence that never scrolls away, and once in the list itself, where everything
/// past the cut greys out as you move the selection.
struct BranchSheet: View {
    let conversationTitle: String
    let points: [BranchPoint]
    /// Every readable message in the conversation, not merely those offered as cut points.
    /// Scaffolding records are filtered out of `points` but are still dropped by a cut, so
    /// deriving the total from `points` understates the consequence.
    let totalMessages: Int
    @Binding var selected: BranchPoint?
    @Binding var newTitle: String
    var onCancel: () -> Void
    var onBranch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            consequence
            Hairline()
            footer
        }
        // Height follows the content; see the note in TransferSheet.
        .frame(width: 660)
        .frame(maxHeight: 680)
        .background(Design.Palette.raised)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Branch conversation")
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.primary)
            Text(conversationTitle)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    // MARK: - Points

    @ViewBuilder
    private var list: some View {
        if points.isEmpty {
            Empty(headline: "Nothing to branch from",
                  detail: "This conversation has no messages yet.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // The column header sits outside the scroll region: scrolling to the
                // selected point on open used to push it away, so the sheet appeared with an
                // unlabelled column of numbers.
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Last message to keep")
                    Spacer()
                    SubHead(text: "\(totalMessages) messages")
                }
                .padding(.horizontal, Design.Space.xl)
                .padding(.top, Design.Space.l)
                .padding(.bottom, Design.Space.s)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(points) { point in
                                BranchPointRow(point: point,
                                               isSelected: selected?.id == point.id,
                                               isDropped: isDropped(point)) {
                                    selected = point
                                }
                                .id(point.id)
                                if selected?.id == point.id { CutRule() }
                            }
                        }
                        .padding(.horizontal, Design.Space.xl)
                        .padding(.bottom, Design.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row pitch runs 34–53pt, so the ramp has to clear the tallest of them
                    // or the cut slices a row through its glyphs.
                    .fadingBottomEdge(72)
                    .onAppear {
                        guard let selected else { return }
                        proxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func isDropped(_ point: BranchPoint) -> Bool {
        guard let selected else { return false }
        return point.messageIndex > selected.messageIndex
    }

    // MARK: - Consequence

    /// Pinned between the list and the footer, because it is the only thing on this screen
    /// that decides anything and a reader who has scrolled to message 200 must still see it.
    private var consequence: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            if let selected {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keeps \(kept) message\(kept == 1 ? "" : "s"). Drops \(dropped).")
                        .font(Design.Typography.heading)
                        .foregroundStyle(Design.Palette.primary)
                    Text("The branch is a copy up to \(roleWord(selected.role)) message \(selected.messageIndex + 1). This conversation is not changed.")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    SectionLabel(text: "Name the branch")
                    TitleField(text: $newTitle)
                }
            } else {
                Text("Pick the last message to keep.")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondary)
                Text("Everything after it stays in the original and is left out of the branch.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A floor rather than a fixed height, so choosing a message reveals the title field
        // without the footer jumping under the pointer.
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    /// The last offered point's position, not `points.count`: a message with no record of
    /// its own cannot be a cut point, and the count a person reads must still be the count
    /// of messages in the conversation.

    private var kept: Int { (selected?.messageIndex ?? -1) + 1 }
    private var dropped: Int { max(0, totalMessages - kept) }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Design.Space.s) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Create branch", action: onBranch)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }
}

private func roleWord(_ role: MessageText.Role) -> String {
    switch role {
    case .user: return "your"
    case .assistant: return "Claude's"
    case .system, .tool, .unknown: return ""
    }
}

private func roleLabel(_ role: MessageText.Role) -> String {
    switch role {
    case .user: return "You"
    case .assistant: return "Claude"
    case .system: return "System"
    case .tool, .unknown: return ""
    }
}

/// One candidate cut.
///
/// Rows past the selection recede to `muted` rather than disappearing: the messages are
/// still there, they simply will not come along, and showing them greyed is a truer picture
/// of the choice than hiding them would be.
private struct BranchPointRow: View {
    let point: BranchPoint
    let isSelected: Bool
    let isDropped: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text("\(point.messageIndex + 1)")
                    .font(Design.Typography.numeric)
                    .foregroundStyle(Design.Palette.muted)
                    .frame(width: 26, alignment: .trailing)
                Text(roleLabel(point.role))
                    .font(Design.Typography.label)
                    .tracking(0.6)
                    .foregroundStyle(Design.Palette.muted)
                    .frame(width: 46, alignment: .leading)
                Text(point.preview)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(isDropped ? Design.Palette.muted : Design.Palette.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Design.Space.m)
                Text(point.timestamp?.compactStamp ?? "")
                    .font(Design.Typography.numeric)
                    .foregroundStyle(Design.Palette.muted)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(roleLabel(point.role)), message \(point.messageIndex + 1). \(point.preview)")
        .accessibilityValue(isDropped ? "Dropped by the current selection" : "Kept")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Design.Palette.selection }
        return isHovering ? Design.Palette.hover : .clear
    }
}

/// The cut, drawn where it falls.
///
/// The only accent on screen besides the primary button, and deliberately so: it is the same
/// selection the chosen row is already filled with, extended into a line, rather than a
/// second thing competing to be clicked.
private struct CutRule: View {
    var body: some View {
        Rectangle()
            .fill(Design.Palette.accent)
            .frame(height: 1)
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
            .accessibilityHidden(true)
    }
}

private struct TitleField: View {
    @Binding var text: String

    var body: some View {
        TextField("Untitled branch", text: $text)
            .textFieldStyle(.plain)
            .font(Design.Typography.body)
            .padding(.horizontal, Design.Space.s)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(Design.Palette.hover)
            )
            .accessibilityLabel("Branch title")
    }
}
