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

    /// ⌘Q while the menu bar icon is on: the windows close and the Dock icon goes, and Better
    /// Claude stays in the menu bar, keeping and watching as before. The menu bar's Quit, ⌥⌘Q,
    /// updates and logging out still quit it completely.
    @MainActor static func closeToMenuBar() {
        guard UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true else { quit(); return }
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        BackupSheet.migrateLastBackup()
        // The sidebar is narrower in this design; forget the width an older version saved.
        if !UserDefaults.standard.bool(forKey: "sidebarWidthReset2") {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView")
            UserDefaults.standard.set(true, forKey: "sidebarWidthReset2")
        }
        AppTips.configure()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        // A window coming back, from the menu bar or by opening the app again, brings the Dock
        // icon back with it.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
    }

    /// With every window closed, the app stays for the menu bar; without the menu bar icon, it
    /// quits like any other app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true)
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
    @State private var showsUpdate = false

    var body: some Scene {
        Window("Better Claude", id: "main") {
            MainWindow()
                .frame(minWidth: 900, minHeight: 580)
                .environment(services)
                .environment(updates)
                .sheet(isPresented: $showsUpdate, onDismiss: { updates.isPresented = false }) {
                    UpdateSheet(model: updates) { updates.isPresented = false }
                }
                .onChange(of: updates.isPresented) { _, presented in
                    guard presented else { showsUpdate = false; return }
                    // A window shows one sheet at a time, and a second one asked for while
                    // another is up never appears. The update waits for the other to close.
                    Task {
                        while updates.isPresented, !showsUpdate,
                              NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        if updates.isPresented { showsUpdate = true }
                    }
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
                if showInMenuBar {
                    Button("Close to Menu Bar") { AppDelegate.closeToMenuBar() }
                        .keyboardShortcut("q")
                    Button("Quit Better Claude") { AppDelegate.quit() }
                        .keyboardShortcut("q", modifiers: [.command, .option])
                } else {
                    Button("Quit Better Claude") { AppDelegate.quit() }
                        .keyboardShortcut("q")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
            }
            CommandGroup(after: .sidebar) {
                Button("Command Palette…") { services.showsPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Look for New Conversations") { services.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Home") { services.go(to: .home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Conversations") { services.go(to: .conversations) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Projects") { services.go(to: .projects) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Usage") { services.go(to: .usage) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Library") { services.go(to: .library) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("This Mac") { services.go(to: .thisMac) }
                    .keyboardShortcut("6", modifiers: .command)
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
                .environment(updates)
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
