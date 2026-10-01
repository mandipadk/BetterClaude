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
                                detail: "Find any conversation from anywhere, without opening the window. ⌘Q then closes to the menu bar, so keeping, alerts and Claude's history keep working; ⌥⌘Q quits completely.",
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
                APIKeyRow()
            } header: {
                Text("Your Anthropic API key")
            } footer: {
                Text("Off unless you add one. It's used only when you replay a conversation on another model, and each replay shows what it will cost first. Kept in your Keychain.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
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
                        .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
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

/// Adding, replacing or removing the API key.
private struct APIKeyRow: View {
    @State private var key = ""
    @State private var isSet = APIKeyStore.isSet
    @State private var failure: String?

    var body: some View {
        HStack {
            if isSet {
                Text("A key is saved.").font(Theme.Font.body)
                Spacer()
                Button("Remove") { APIKeyStore.remove(); isSet = false }.buttonStyle(.bordered)
            } else {
                SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
                Button("Save") {
                    do {
                        try APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        key = ""
                        isSet = true
                        failure = nil
                    } catch {
                        failure = "Couldn't save it to the Keychain."
                    }
                }
                .buttonStyle(.bordered)
                .disabled(key.trimmingCharacters(in: .whitespaces).count < 20)
            }
        }
        if let failure { Text(failure).font(Theme.Font.callout).foregroundStyle(Theme.failure) }
    }
}

/// The fork mark as a template image, for the menu bar.
enum MenuBarIcon {
    /// The b as a template image, so the menu bar tints it like every other item.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(BMarkShape().path(in: rect.insetBy(dx: 1.5, dy: 1)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Better Claude"
        return image
    }()
}
