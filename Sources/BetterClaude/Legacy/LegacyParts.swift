import CoworkKit
import SwiftUI

// Parts of the previous design still used by the screens not yet rebuilt (Library, the
// transfer and branch sheets, and the setup lists). They go when those screens do.

/// The old custom chrome reserved room for the traffic lights; the new window has a toolbar.
enum WindowMetrics {
    static let titlebarInset: CGFloat = 0
}

struct SearchField: View {
    @Binding var text: String
    var focusRequest: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Design.Palette.faint)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Design.Typography.body)
                .tint(Design.Palette.secondary)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Palette.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                .fill(Design.Palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                .strokeBorder(focused ? Design.Palette.secondary : Design.Palette.controlStroke,
                              lineWidth: 1)
        )
        // Without this the only hit target is the glyphs of the text itself, so clicking
        // anywhere in the field's chrome does nothing and typing goes to the list instead.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

struct Empty: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(spacing: Design.Space.xs) {
            Text(headline)
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.secondary)
            Text(detail)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondary)
                // Centred and bounded. With neither, a long detail line ran to 3.5pt from
                // the window edge at the minimum size — past the pane's own 16pt rail —
                // and, being leading-aligned inside a centred frame, wrapped full-bleed on
                // line one and ragged on line two. Shared by every empty state, so the
                // measure belongs here rather than at each call site.
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A floor as well as a ceiling. `fixedSize(vertical:)` under a maxWidth with no
        // minimum answers a zero-width proposal by wrapping to roughly one character per
        // line, which published a 1828pt minimum height for the first-run Library pane. The
        // window's own minimum absorbs it today, so this is a landmine rather than a live
        // defect — but any future container that asks Empty for its minimum would get that.
        .frame(minWidth: 240, maxWidth: 440)
        .gutter()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

