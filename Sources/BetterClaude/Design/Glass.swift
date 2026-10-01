import SwiftUI

// Glass belongs to the navigation layer only (the toolbar, the sidebar, the menu bar panel),
// and macOS draws it there on its own. Content sits on the system's grouped fill instead,
// and buttons are the system's, so the app follows macOS as it changes.

extension View {
    /// The one container for content: the system's grouped fill in a continuous rounded
    /// rectangle. Never tinted to signal state.
    func groupSurface(cornerRadius: CGFloat = Theme.Radius.group) -> some View {
        background(Theme.groupFill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The one thing to do next in a sheet or onboarding: the system's prominent button.
    func prominentAction() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large)
    }

    /// A quiet action beside a prominent one.
    func quietAction() -> some View {
        buttonStyle(.bordered).controlSize(.large)
    }

    /// A bar pinned to the bottom of a scrolling view; content scrolling beneath it softens
    /// away with the system's scroll-edge effect.
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        safeAreaBar(edge: .bottom, spacing: 0, content: bar)
    }
}
