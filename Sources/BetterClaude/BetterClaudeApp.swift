import CoworkKit
import SwiftUI

@main
struct BetterClaudeApp: App {
    @State private var services = AppServices()
    @State private var updates = UpdateModel()
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @State private var showsWhatsNew = false

    var body: some Scene {
        Window("Better Claude", id: "main") {
            MainWindow()
                .frame(minWidth: 900, minHeight: 580)
                .environment(services)
                .environment(updates)
                .sheet(isPresented: Binding(get: { updates.isPresented },
                                            set: { updates.isPresented = $0 })) {
                    UpdateSheet(model: updates) { updates.isPresented = false }
                }
                .sheet(isPresented: $showsWhatsNew) {
                    WhatsNewSheet(version: updates.currentVersion) { showsWhatsNew = false }
                }
                .task {
                    DebugRoute.apply(to: services)
                    updates.start()
                    showsWhatsNew = WhatsNewCheck.shouldShow(version: updates.currentVersion)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
            }
            CommandGroup(after: .sidebar) {
                Button("Conversations") { services.destination = .conversations }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Library") { services.destination = .library }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPanel()
                .environment(services)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// What's New shows once per version after an update — never on a first install, where the
/// welcome does that job.
enum WhatsNewCheck {
    static let key = "lastSeenVersion"

    static func shouldShow(version: String) -> Bool {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: key)
        defaults.set(version, forKey: key)
        #if DEBUG
        if ProcessInfo.processInfo.environment["BC_UI_ROUTE"] == "whatsnew" { return true }
        #endif
        let upgraded = last != nil || defaults.bool(forKey: "onboardingCompleted")
            || defaults.object(forKey: "lastUpdateCheck") != nil
        return upgraded && last != version && ReleaseHighlights.items(for: version) != nil
    }
}
