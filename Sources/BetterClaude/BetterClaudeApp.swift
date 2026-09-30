import CoreSpotlight
import CoworkKit
import SwiftUI

/// AppKit won't quit while a window has a sheet open — Quit, the updater's restart and a quit
/// sent by another app all fail silently — so every way of quitting closes sheets first.
/// Nothing in a sheet is lost that wasn't only on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static func quit() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { Self.quit() }
    }
}

@main
struct BetterClaudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onOpenURL { url in
                    if !services.hasLoaded { services.refresh() }
                    Task {
                        while !services.hasLoaded { try? await Task.sleep(for: .milliseconds(50)) }
                        services.open(url)
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    Task {
                        while !services.hasLoaded { try? await Task.sleep(for: .milliseconds(50)) }
                        services.openSpotlightItem(id)
                    }
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
            CommandGroup(after: .newItem) {
                Button("Import claude.ai Export…") { services.importClaudeWebExport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Open Another Mac's Backup…") { services.openOtherMac() }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Better Claude") { AppDelegate.quit() }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
            }
            CommandGroup(after: .sidebar) {
                Button("Conversations") { services.destination = .conversations }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Running") { services.destination = .running }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Ask") { services.destination = .ask }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Usage") { services.destination = .usage }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Library") { services.destination = .library }
                    .keyboardShortcut("5", modifiers: .command)
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
                .environment(services)
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
        if let route = ProcessInfo.processInfo.environment["BC_UI_ROUTE"], !route.isEmpty {
            // A screenshot of any other screen shouldn't have What's New over it.
            return route == "whatsnew"
        }
        #endif
        let upgraded = last != nil || defaults.bool(forKey: "onboardingCompleted")
            || defaults.object(forKey: "lastUpdateCheck") != nil
        // Within one release, only a fix release with highlights of its own is worth showing.
        let sameRelease = last.map { ReleaseHighlights.series(of: $0) == ReleaseHighlights.series(of: version) } ?? false
        if sameRelease, ReleaseHighlights.byVersion[version] == nil { return false }
        return upgraded && last != version && ReleaseHighlights.items(for: version) != nil
    }
}
