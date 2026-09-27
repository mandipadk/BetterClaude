import AppKit
import SwiftUI

// Liquid Glass on macOS 26, the closest material look before it. Every
// surface that floats (panels, tiles, name tags, capsule buttons) goes
// through these so the app has one consistent depth language.

extension View {
    /// A floating glass surface.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Theme.Radius.panel, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.hairline))
        }
    }

    /// Glass shaped as a capsule (name tags, chips).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.hairline))
        }
    }

    /// The prominent action: a solid accent capsule on every system.
    ///
    /// Not tinted glass: with the classic window chrome this app opts into, glass drops its
    /// tint and the one action that matters renders as grey as the one beside it.
    func prominentAction() -> some View {
        self.buttonStyle(CapsuleButtonStyle(prominent: true))
    }

    /// A quiet capsule action next to a prominent one.
    @ViewBuilder
    func quietAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(GlassCapsuleButtonStyle(prominent: false))
        } else {
            self.buttonStyle(CapsuleButtonStyle(prominent: false))
        }
    }
}

/// Liquid Glass capsule buttons: accent-tinted glass for the primary action,
/// clear glass (never tinted) for the quiet one beside it.
@available(macOS 26.0, *)
struct GlassCapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 22)
            .frame(height: 40)
            .contentShape(.capsule)
            .glassEffect(
                prominent ? .regular.tint(Theme.accent.opacity(isEnabled ? 1 : 0.45)).interactive() : .regular.interactive(),
                in: .capsule
            )
            .opacity(isEnabled || prominent ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.fade, value: configuration.isPressed)
    }
}

/// Capsule buttons for systems without Liquid Glass.
struct CapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background {
                if prominent {
                    Capsule().fill(Theme.accentFill.opacity(isEnabled ? 1 : 0.4))
                } else {
                    Capsule().fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.fade, value: configuration.isPressed)
    }
}

/// The desktop showing through the window, frosted — behind-window vibrancy.
struct WindowGlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// A bar pinned to the bottom of a scrolling view. On macOS 26 it's a
    /// safe-area bar, so content scrolling beneath it softens away (the
    /// system scroll-edge effect) instead of showing through; earlier, an
    /// inset with a bar material.
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                bar().background(.bar)
            }
        }
    }
}
