import SwiftUI

@main
struct BetterClaudeApp: App {
    @State private var updates = UpdateModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 560)
                .environment(updates)
                .sheet(isPresented: Binding(get: { updates.isPresented },
                                            set: { updates.isPresented = $0 })) {
                    UpdateSheet(model: updates) { updates.isPresented = false }
                }
                // Without this, text carets, focus rings and controls inherit the system
                // accent — which is blue by default and would reintroduce a second hue.
                .tint(Design.Palette.accent)
        }
        .defaultSize(width: 1060, height: 700)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Sits where macOS users look for it: directly under About in the app menu.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
            }
        }
    }
}
