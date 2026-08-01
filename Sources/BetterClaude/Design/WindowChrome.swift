import AppKit
import SwiftUI

/// Takes over the window's chrome so the app paints its own surface edge to edge.
///
/// Two things force this. macOS renders an empty toolbar as a cool-grey material that is
/// noticeably blue and, being full-width and empty, ends up the largest coloured area in the
/// window. And `NavigationSplitView` on recent macOS draws the sidebar as an inset, stroked,
/// floating panel — a card, which this design does not use. Owning the window lets the app
/// present one continuous surface and draw its own single dividing rule.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Design.Palette.background)
        window.toolbar = nil
    }
}

extension View {
    func ownsWindowChrome() -> some View {
        background(WindowChrome().frame(width: 0, height: 0))
    }
}

/// Height reserved at the top of the sidebar so content clears the traffic lights, which
/// overlay the content once the titlebar is transparent and full-size.
enum WindowMetrics {
    static let titlebarInset: CGFloat = 30
}
