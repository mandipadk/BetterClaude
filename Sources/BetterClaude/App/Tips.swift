import SwiftUI
import TipKit

/// One-time tips, each shown once, at the moment it helps. Dismissing one never hides the
/// feature it's about.
struct PaletteTip: Tip {
    var title: Text { Text("Find anything with ⌘K") }
    var message: Text? { Text("Pages, actions on the conversation you're reading, and every conversation by name. ⌘↩ asks your history instead.") }
}

struct ReaderTip: Tip {
    var title: Text { Text("Details beside the conversation") }
    var message: Text? { Text("⌥⌘I shows what it cost, who was working when and what it changed. Right-click a message to fork from it.") }
}

enum AppTips {
    static func configure() {
        #if DEBUG
        // Captures show tips only when they ask for them.
        if ProcessInfo.processInfo.environment["BC_UI_ROUTE"] != nil,
           (ProcessInfo.processInfo.environment["BC_TIPS"] ?? "").isEmpty {
            Tips.hideAllTipsForTesting()
        }
        #endif
        #if DEBUG
        // A capture asking for tips starts from a clean slate, so they show.
        if !(ProcessInfo.processInfo.environment["BC_TIPS"] ?? "").isEmpty { try? Tips.resetDatastore() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
