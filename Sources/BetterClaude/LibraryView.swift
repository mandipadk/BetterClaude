import AppKit
import CoworkKit
import SwiftUI

/// Everything Claude ever made, in one list.
///
/// The organising claim is that an artifact is only reusable if you can see where it came
/// from: a snippet with no conversation behind it is a fragment you have to re-derive trust
/// in. Provenance therefore sits in the row itself, not behind a hover or a disclosure — it is
/// a column, next to the numbers, on every line.
struct LibraryView: View {
    let summary: HarvestSummary?
    let isHarvesting: Bool
    @Binding var query: String
    @Binding var kindFilter: ArtifactKind?
    @Binding var selected: Artifact?
    var onHarvest: () -> Void
    var onReveal: (Artifact) -> Void      // show in Finder / jump to conversation
    var onCopy: (Artifact) -> Void

    var body: some View {
        // Filtered once per pass and handed down: searching rebuilds a haystack per artifact,
        // which is cheap once and noticeable three times on every keystroke.
        let visible = artifacts
        return VStack(spacing: 0) {
            header
            Hairline()
            if let summary {
                Hairline()
                content(summary, visible: visible)
                Hairline()
                footer(summary)
            } else {
                unharvested
            }
        }
    }

    // MARK: - Rows in view

    private var artifacts: [Artifact] {
        guard let summary else { return [] }
        let byKind = kindFilter.map { kind in summary.artifacts.filter { $0.kind == kind } }
            ?? summary.artifacts
        return ArtifactHarvest.search(byKind, query: query)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Library")
                    .font(Design.Typography.title)
                    .foregroundStyle(Design.Palette.primary)
                Text(subtitle)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.Space.l)
            if isHarvesting { ProgressView().controlSize(.small).scaleEffect(0.7) }
            SearchField(text: $query)
                .frame(width: 190)
            // The accent belongs to the action the screen exists for. Before a harvest that
            // is the harvest; afterwards it moves to Copy in the preview, and re-harvesting
            // becomes an ordinary maintenance action.
            Button(summary == nil ? "Harvest" : "Re-harvest", action: onHarvest)
                .buttonStyle(summary == nil ? AnyButtonStyle(PrimaryButtonStyle())
                                            : AnyButtonStyle(QuietButtonStyle()))
                .disabled(isHarvesting)
        }
        .padding(.leading, Design.Space.gutter)
        .padding(.trailing, Design.Space.m)
        .padding(.top, WindowMetrics.titlebarInset)
        .padding(.bottom, Design.Space.m)
    }

    private var subtitle: String {
        guard let summary else {
            return isHarvesting ? "Reading every conversation once…" : "Nothing gathered yet"
        }
        let kept = summary.artifacts.count
        return "\(kept) artifact\(kept == 1 ? "" : "s") · \(summary.totalBytes.fileSize) · "
            + "\(summary.conversationsScanned) conversation\(summary.conversationsScanned == 1 ? "" : "s")"
    }

    // MARK: - Filter

    // MARK: - Content

    @ViewBuilder
    private func content(_ summary: HarvestSummary, visible: [Artifact]) -> some View {
        if summary.artifacts.isEmpty {
            Empty(headline: "Nothing to gather",
                  detail: "No code blocks or files were found in \(summary.conversationsScanned) conversations.")
        } else if visible.isEmpty {
            Empty(headline: "Nothing here matches",
                  detail: "No artifact matches “\(query)”.")
        } else {
            HStack(spacing: 0) {
                list(visible)
                // The preview appears only once there is something to preview. Reserving a
                // third of the window for "Nothing selected" starved the artifact-name
                // column badly enough that filenames truncated to their extensions.
                if selected != nil {
                    Rectangle()
                        .fill(Design.Palette.separator)
                        .frame(width: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
                    ArtifactPreview(artifact: selected, onReveal: onReveal, onCopy: onCopy)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: Design.Duration.quick), value: selected == nil)
        }
    }

    private func list(_ visible: [Artifact]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, artifact in
                    ArtifactRow(artifact: artifact, showsProvenance: selected == nil,
                                isSelected: selected?.id == artifact.id) {
                        selected = artifact
                    }
                    if index < visible.count - 1 { Hairline() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fadingBottomEdge(56)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private func footer(_ summary: HarvestSummary) -> some View {
        HStack(spacing: Design.Space.s) {
            Text(summary.duplicatesCollapsed == 0
                 ? "No duplicates"
                 : "\(summary.duplicatesCollapsed) duplicate\(summary.duplicatesCollapsed == 1 ? "" : "s") collapsed")
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
            if !summary.skipped.isEmpty {
                // What a harvest declined to read is part of what makes its numbers
                // trustworthy, so it is stated rather than hidden behind a tooltip.
                Text("skipped \(summary.skipped.joined(separator: ", "))")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Design.Space.m)
            if let artifact = selected {
                Button(artifact.inlineContent == nil ? "Show in Finder" : "Open conversation") {
                    onReveal(artifact)
                }
                .buttonStyle(QuietButtonStyle())
                Button(artifact.inlineContent == nil ? "Copy path" : "Copy code") {
                    onCopy(artifact)
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                // Reserve the action row's height so the footer does not change size — and
                // so it matches the 85px bar every other pane has.
                Color.clear.frame(height: 26)
            }
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, Design.Space.s)
    }

    // MARK: - Before the first harvest

    private var unharvested: some View {
        Group {
            if isHarvesting {
                VStack(spacing: Design.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading every conversation once…")
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Empty(headline: "Nothing gathered yet",
                      detail: "Harvest to collect every code block, generated file and upload from your conversations.")
            }
        }
    }
}

// MARK: - Filter control

/// A text filter with an accent rule under the selected one. Not a chip: a filled pill in a
/// row of filled pills is a row of cards.
private struct KindFilter: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.xs) {
                Text(title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(isSelected ? Design.Palette.primary : Design.Palette.secondary)
                Text("\(count)")
                    .font(Design.Typography.numeric)
                    .foregroundStyle(Design.Palette.muted)
            }
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Design.Palette.accent
                                     : (isHovering ? Design.Palette.separator : .clear))
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Row

/// One artifact per line, with the metadata in fixed-width columns so the eye can run down
/// any one of them without re-finding its edge on every row.
private struct ArtifactRow: View {
    let artifact: Artifact
    /// Provenance yields its column when the preview is open — the preview names the source
    /// conversation anyway, and the row's own identifier must not be the thing that starves.
    let showsProvenance: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    /// A harvested block with no derivable name still has to be selectable, so it is
    /// labelled by what it is rather than left blank.
    private var fallbackTitle: String {
        artifact.language.map { "\($0) snippet" } ?? "\(artifact.kind.label) snippet"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.m) {
                // The artifact's own name must win the width fight: without a priority the
                // flexible column collapses to nothing against its fixed-width siblings and
                // the row appears to be titled by its conversation.
                // The artifact's own name is the primary identifier, so it takes the
                // flexible width and truncates at the *head*: these filenames share long
                // prefixes and differ only at the end, which middle truncation ate.
                // These filenames share long prefixes and differ at the end, so the middle
                // is what can be spared. The floor matters more than the priority: a
                // `maxWidth: .infinity` column does not defend itself against fixed and
                // min-width siblings, and collapsed to ~70pt with the preview open.
                Text(artifact.title.isEmpty ? fallbackTitle : artifact.title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(artifact.title.isEmpty ? Design.Palette.muted : Design.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(minWidth: 140, maxWidth: 420, alignment: .leading)
                    .layoutPriority(1)
                Text(artifact.conversationTitle)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    .frame(minWidth: showsProvenance ? 150 : 0,
                           maxWidth: showsProvenance ? 180 : 150, alignment: .leading)
                    .layoutPriority(showsProvenance ? 1 : 0)
                // Language and line count are both restated in the preview, so these are
                // what yield when the pane narrows.
                if showsProvenance {
                    Text(artifact.language ?? artifact.kind.label.lowercased())
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                    Text(artifact.lineCount.map { "\($0)" } ?? "—")
                        .font(Design.Typography.numeric)
                        .foregroundStyle(Design.Palette.muted)
                        .frame(width: 44, alignment: .trailing)
                }
                Text(Int64(artifact.bytes).fileSize)
                    .font(Design.Typography.numeric)
                    .foregroundStyle(Design.Palette.secondary)
                    .frame(width: 62, alignment: .trailing)
                if showsProvenance {
                    Text(artifact.createdAt?.compactStamp ?? "—")
                        .font(Design.Typography.numeric)
                        .foregroundStyle(Design.Palette.secondary)
                        .frame(width: 74, alignment: .trailing)
                }
            }
            .padding(.horizontal, Design.Space.gutter)
            .frame(height: Design.Space.rowHeight)
            .background(isSelected ? Design.Palette.selection
                                   : (isHovering ? Design.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artifact.title)
        .accessibilityValue("\(artifact.kind.label), from \(artifact.conversationTitle), \(Int64(artifact.bytes).fileSize)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Preview

private struct ArtifactPreview: View {
    let artifact: Artifact?
    let onReveal: (Artifact) -> Void
    let onCopy: (Artifact) -> Void

    var body: some View {
        if let artifact {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        heading(artifact)
                        provenance(artifact)
                        if let content = artifact.inlineContent {
                            code(content)
                        } else if let url = artifact.fileURL {
                            path(url)
                        }
                        Color.clear.frame(height: Design.Space.l)
                    }
                    .padding(.horizontal, Design.Space.gutter)
                    .padding(.top, Design.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                Hairline()
            }
        } else {
            Empty(headline: "Nothing selected",
                  detail: "Choose an artifact to see it.")
        }
    }

    private func heading(_ artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artifact.title)
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(descriptor(artifact))
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.muted)
        }
    }

    private func descriptor(_ artifact: Artifact) -> String {
        var parts = [artifact.kind.label]
        if let language = artifact.language { parts.append(language) }
        if let lines = artifact.lineCount { parts.append("\(lines) line\(lines == 1 ? "" : "s")") }
        parts.append(Int64(artifact.bytes).fileSize)
        return parts.joined(separator: " · ")
    }

    /// The conversation an artifact came from, spelled out. This is the whole reason the
    /// preview exists as more than a text box.
    private func provenance(_ artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            SubHead(text: "From")
            field("Conversation", artifact.conversationTitle)
            field("Where", artifact.container)
            if let created = artifact.createdAt {
                field("Made", created.formatted(date: .abbreviated, time: .shortened))
            }
            field("Fingerprint", String(artifact.contentHash.prefix(12)))
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(label)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.muted)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// A leading rule, never a filled panel: a shaded code block is a card.
    private func code(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            SubHead(text: "Content")
            Text(String(content.prefix(4000)))
                .font(Design.Typography.mono)
                .foregroundStyle(Design.Palette.secondary)
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Design.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Design.Palette.separator)
                        .frame(width: 2)
                }
        }
    }

    private func path(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            SubHead(text: "On disk")
            Text(url.path.abbreviatingHome)
                .font(Design.Typography.mono)
                .foregroundStyle(Design.Palette.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Design.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Design.Palette.separator)
                        .frame(width: 2)
                }
        }
    }

}

// MARK: - Style erasure

/// `buttonStyle(_:)` fixes the style's type at the call site, so a control that changes style
/// with state needs one erased box rather than two branches of an `if`.
private struct AnyButtonStyle: ButtonStyle {
    private let make: @MainActor (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
