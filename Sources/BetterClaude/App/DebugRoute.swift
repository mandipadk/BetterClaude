import AppKit
import CoworkKit
import Foundation

/// Opens a specific screen at launch so every screen can be photographed from a sample Mac
/// without clicking through the app. Debug builds only:
///
///     BC_FIXTURE_ROOT=<sample> BC_UI_ROUTE=reader:Lisbon  open BetterClaude.app
///
/// `BC_APPEARANCE=light|dark` pins the appearance for the capture.
///
/// Routes: `conversations`, `reader:<title words>`, `install:<name>`, `library`,
/// `filter:<install name>`, `search:<query>`, `messages:<query>`.
enum DebugRoute {
    @MainActor
    static func apply(to services: AppServices) {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["BC_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let raw = ProcessInfo.processInfo.environment["BC_UI_ROUTE"], !raw.isEmpty else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        Task { @MainActor in
            // Routes act on what the first scan finds.
            while !services.hasLoaded { try? await Task.sleep(for: .milliseconds(50)) }
            switch parts[0] {
            case "conversations":
                services.destination = .conversations
            case "reader":
                services.destination = .conversations
                if let match = services.snapshot.conversations.first(where: {
                    $0.title.localizedCaseInsensitiveContains(argument)
                }) {
                    services.selectedConversationID = match.id
                }
            case "filter":
                if let install = services.installs.first(where: { $0.name == argument }) {
                    services.filter = .install(install.id)
                }
            case "install":
                if let install = services.installs.first(where: { $0.name == argument }) {
                    services.destination = .install(install.id)
                }
            case "library":
                services.destination = .library
            case "search":
                services.query = argument
            case "messages":
                services.query = argument
                services.search.search(argument, in: services.snapshot)
            default:
                break
            }
        }
        #endif
    }
}
