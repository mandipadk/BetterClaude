import CoworkKit
import SwiftUI

@main
struct BetterClaudeApp: App {
    @State private var services = AppServices()
    @State private var updates = UpdateModel()
    @AppStorage("showInMenuBar") private var showInMenuBar = true

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
                .task { DebugRoute.apply(to: services) }
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
            Image(systemName: "bubble.left.and.text.bubble.right")
                .accessibilityLabel("Better Claude")
        }
        .menuBarExtraStyle(.window)
    }
}
