import SwiftUI

@main
struct BetterClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 560)
                // Without this, text carets, focus rings and controls inherit the system
                // accent — which is blue by default and would reintroduce a second hue.
                .tint(Design.Palette.accent)
        }
        .defaultSize(width: 1060, height: 700)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
