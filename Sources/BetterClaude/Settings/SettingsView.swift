import AppKit
import CoworkKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(SpotlightIndexer.enabledKey) private var showInSpotlight = true
    @AppStorage("keepAutomatically") private var keepAutomatically = true
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("onboardingCompleted") private var onboardingCompleted = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                ExplainedToggle(title: "Keep conversations automatically",
                                detail: "Copies each Claude Code conversation as it changes, before Claude Code's cleanup deletes it.",
                                isOn: $keepAutomatically)
                ExplainedToggle(title: "Show in the menu bar",
                                detail: "Find any conversation from anywhere, without opening the window.",
                                isOn: $showInMenuBar)
                ExplainedToggle(title: "Show conversations in Spotlight",
                                detail: "Their titles, where they happened and what you first asked. Never whole conversations.",
                                isOn: Binding(get: { showInSpotlight }, set: { services.setShowsInSpotlight($0) }))
                ExplainedToggle(title: "Open at login",
                                detail: loginError ?? "So conversations are kept, and you hear when Claude needs you, even on days you don't open Better Claude.",
                                // A closure, not the method itself: Swift 6.3 crashes building the
                                // thunk for a main-actor method passed as a setter.
                                isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome").font(Theme.Font.body)
                        Text("See the introduction again, next time the window opens.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Welcome") { onboardingCompleted = false }
                        .buttonStyle(.secondary)
                }
            }
            Section {
                HStack(spacing: Theme.Space.m) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Better Claude").font(Theme.Font.headline)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Its Data") {
                        NSWorkspace.shared.activateFileViewerSelecting([HostPaths.current.betterClaudeSupport])
                    }
                    .buttonStyle(.secondary)
                }
            } footer: {
                Text("Better Claude reads what Claude keeps on this Mac. Nothing leaves it, apart from checking for updates when you ask.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            openAtLogin = on
            loginError = nil
        } catch {
            loginError = "macOS didn't allow it: \(error.localizedDescription)"
        }
    }
}

/// The fork mark as a template image, for the menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s = rect.width / 520
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x + 260) * s, y: (760 - y) * s) }
            let path = NSBezierPath()
            path.lineWidth = 72 * s
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: p(-172, 730)); path.line(to: p(0, 545)); path.line(to: p(0, 300))
            path.move(to: p(172, 730)); path.line(to: p(0, 545))
            NSColor.black.setStroke()
            path.stroke()
            NSColor.black.setFill()
            for point in [p(-172, 730), p(172, 730), p(0, 300)] {
                let r = 52 * s
                NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Better Claude"
        return image
    }()
}
