import AppKit
import CoworkKit
import ServiceManagement
import SwiftUI

/// Settings, in the standard window with tabs in its toolbar. Everything set once lives
/// here, including every notification, which used to be spread over Running and Usage.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell", value: "notifications") { NotificationSettings() }
            Tab("Claude Access", systemImage: "person.crop.circle", value: "access") { AccessSettings() }
            Tab("API Key", systemImage: "key", value: "key") { APIKeySettings() }
            Tab("Updates", systemImage: "arrow.down.circle", value: "updates") { UpdateSettings() }
        }
        .frame(width: 560)
    }
}

/// A switch with its title and one line saying what it does.
private struct SettingToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

private struct GeneralSettings: View {
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
                SettingToggle(title: "Keep conversations automatically",
                              detail: "Copies each Claude Code conversation as it changes, before Claude Code's cleanup deletes it.",
                              isOn: $keepAutomatically)
                SettingToggle(title: "Show in the menu bar",
                              detail: "⌘Q then closes to the menu bar, so keeping and notifications carry on. ⌥⌘Q quits.",
                              isOn: $showInMenuBar)
                SettingToggle(title: "Show conversations in Spotlight",
                              detail: "Titles, where they happened and what you first asked. Never whole conversations.",
                              isOn: Binding(get: { showInSpotlight }, set: { services.setShowsInSpotlight($0) }))
                // A closure, not the method itself: Swift 6.3 crashes building the thunk for a
                // main-actor method passed as a setter.
                SettingToggle(title: "Open at login",
                              detail: loginError ?? "So conversations are kept and you hear when Claude needs you, even on days you don't open it.",
                              isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
            }
            Section {
                LabeledContent("Welcome") {
                    Button("Show Again") { onboardingCompleted = false }
                }
                LabeledContent("Better Claude's data") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HostPaths.current.betterClaudeSupport])
                    }
                }
            } footer: {
                Text("Better Claude reads what Claude keeps on this Mac. Nothing leaves it, apart from checking for updates and replays you ask for.")
            }
        }
        .formStyle(.grouped)
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

private struct NotificationSettings: View {
    @Environment(AppServices.self) private var services
    @AppStorage(PulseNotifier.needsYouKey) private var needsYou = true
    @AppStorage(PulseNotifier.finishedKey) private var finished = true
    @AppStorage(PulseNotifier.contextKey) private var context = true
    @AppStorage(PulseNotifier.cacheKey) private var cache = true
    @AppStorage(PulseNotifier.limitsKey) private var limits = true
    /// These two follow an older switch until they're set (see PulseNotifier.setting).
    @State private var jobs = PulseNotifier.setting(PulseNotifier.jobsKey, fallback: PulseNotifier.finishedKey)
    @State private var drift = PulseNotifier.setting(PulseNotifier.driftKey, fallback: PulseNotifier.contextKey)
    @State private var hookError: String?

    var body: some View {
        Form {
            Section {
                SettingToggle(title: "When Claude needs you", detail: "A question or a permission, while you're in another app.", isOn: $needsYou)
                SettingToggle(title: "When a long turn finishes", detail: "After Claude has worked for a minute or more.", isOn: $finished)
                SettingToggle(title: "When a background job ends",
                              detail: "A job started with claude --bg or /fork finishes, fails, or stops.",
                              isOn: Binding(get: { jobs }, set: { jobs = $0; UserDefaults.standard.set($0, forKey: PulseNotifier.jobsKey) }))
            } header: {
                Text("Sessions")
            }
            Section {
                SettingToggle(title: "When context is filling up", detail: "At 75% and 90% of the context window.", isOn: $context)
                SettingToggle(title: "When a model changes on its own",
                              detail: "Replies come from a different model with nothing on record asking for it.",
                              isOn: Binding(get: { drift }, set: { drift = $0; UserDefaults.standard.set($0, forKey: PulseNotifier.driftKey) }))
                SettingToggle(title: "Before a waiting cache expires",
                              detail: "Two minutes before, for conversations over 80K tokens.", isOn: $cache)
                SettingToggle(title: "Before you hit a limit", detail: "At 80% and 95% of a five-hour or weekly limit.", isOn: $limits)
            } header: {
                Text("While you work")
            }
            Section {
                SettingToggle(title: "Say what Claude asked",
                              detail: hookError ?? "Adds three small hooks to Claude Code's settings, so a notification can include Claude's question. Turning it off takes out exactly those hooks.",
                              isOn: Binding(get: { services.pulse.hooksInstalled }, set: { setHooks($0) }))
            }
        }
        .formStyle(.grouped)
    }

    private func setHooks(_ on: Bool) {
        do {
            try services.pulse.setHooks(on)
            hookError = nil
        } catch {
            hookError = "Couldn't change Claude Code's settings: \(error.localizedDescription)"
        }
    }
}

private struct AccessSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let installs = services.installs.filter { RecallConnection.target(for: $0) != nil }
        Form {
            if installs.isEmpty {
                Text("No Claude on this Mac can search your history yet.").foregroundStyle(.secondary)
            } else {
                ForEach(installs) { install in
                    Section {
                        RecallSection(install: install, embedded: true)
                    } header: {
                        Label { Text(install.name) } icon: { InstallIcon(install: install, size: 16) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }
}

private struct APIKeySettings: View {
    var body: some View {
        Form {
            Section {
                APIKeyRow()
            } footer: {
                Text("Off unless you add one. It's used only when you replay a conversation on another model, and each replay shows what it will cost first. Kept in your Keychain.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Environment(UpdateModel.self) private var updates
    @AppStorage(UpdateModel.Keys.automatic) private var automatic = true

    var body: some View {
        Form {
            Section {
                SettingToggle(title: "Check for updates automatically",
                              detail: "Once a day. A new version waits in the sidebar until you choose to install it.",
                              isOn: $automatic)
                LabeledContent("Better Claude \(updates.currentVersion)") {
                    Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                }
            }
        }
        .formStyle(.grouped)
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
                Text("A key is saved.")
                Spacer()
                Button("Remove") { APIKeyStore.remove(); isSet = false }
            } else {
                SecureField("Anthropic API key", text: $key, prompt: Text("sk-ant-…"))
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
                .disabled(key.trimmingCharacters(in: .whitespaces).count < 20)
            }
        }
        if let failure { Text(failure).foregroundStyle(Theme.failure) }
    }
}

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
