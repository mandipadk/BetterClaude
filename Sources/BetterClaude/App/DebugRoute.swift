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
/// Routes: `conversations`, `reader:<title words>`, `install:<name>`, `library[:everything|files|images|code|uploads]`,
/// `filter:<install name>`, `search:<query>`, `messages:<query>`, `history`,
/// `continue:<title words>`, `continue-review:<title words>`, `fork:<title words>`,
/// `compare:<install>|<install>`, `panel`, `kept`, `storage`, `memory`.
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
            case "compare":
                let names = argument.components(separatedBy: "|")
                if names.count == 2,
                   let left = services.installs.first(where: { $0.name == names[0] }),
                   let right = services.installs.first(where: { $0.name == names[1] }) {
                    services.destination = .install(left.id)
                    services.comparing = InstallComparison(left: left, right: right)
                }
            case "library":
                services.destination = .library
                if let filter = LibraryFilter(rawValue: argument) { services.library.filter = filter }
                while services.library.summary == nil { try? await Task.sleep(for: .milliseconds(50)) }
                services.library.selectedID = services.library.visible.first?.id
            case "panel":
                services.previewsMenuBarPanel = true
            case "history":
                services.destination = .history
            case "kept":
                services.destination = .kept
            case "storage":
                services.destination = .storage
            case "memory":
                services.destination = .memory
                if !argument.isEmpty {
                    while !services.memory.loaded { try? await Task.sleep(for: .milliseconds(50)) }
                    services.memory.selectedID = services.memory.groups.first { $0.title == argument }?.id
                }
            case "continue", "continue-review":
                if let match = services.snapshot.conversations.first(where: {
                    $0.title.localizedCaseInsensitiveContains(argument)
                }) {
                    services.selectedConversationID = match.id
                    services.beginContinue(match)
                    if parts[0] == "continue-review", let model = services.continuing {
                        model.destination = services.installs
                            .first { $0.isParallex }
                            .flatMap { install in
                                services.snapshot.accounts[install.id]?.first(where: \.isSignedIn)
                                    .map { .account(installID: install.id, $0) }
                            }
                        model.review(in: services.snapshot)
                    }
                }
            case "fork":
                if let match = services.snapshot.conversations.first(where: {
                    $0.title.localizedCaseInsensitiveContains(argument)
                }) {
                    services.selectedConversationID = match.id
                    while services.reader.state != .ready { try? await Task.sleep(for: .milliseconds(50)) }
                    if let first = services.reader.forkPoints.keys.sorted().first {
                        services.forking = ForkRequest(messageID: first)
                    }
                }
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
