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
/// Routes: `onboarding:<page>`, `conversations`, `reader:<title words>`, `install:<name>`, `library[:everything|files|images|code|uploads]`,
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
            case "inspector":
                // `inspector:<tab>:<title words>`: the reader with its inspector open on a tab.
                let pieces = argument.split(separator: ":", maxSplits: 1).map(String.init)
                services.inspectorTab = InspectorTab(rawValue: pieces.first ?? "") ?? .info
                services.showsInspector = true
                services.destination = .conversations
                if let words = pieces.last, let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(words) }) {
                    services.selectedConversationID = match.id
                }
            case "settings":
                UserDefaults.standard.set(argument.isEmpty ? "general" : argument, forKey: "settingsTab")
                // The app menu's own Settings… item, as if chosen.
                try? await Task.sleep(for: .seconds(1))
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    menu.performActionForItem(at: index)
                }
            case "home":
                services.destination = .home
            case "thismac":
                services.destination = .thisMac
            case "accuracy":
                UserDefaults.standard.set(true, forKey: "debugOpenAccuracy")
                services.destination = .thisMac
            case "conversations":
                services.destination = .conversations
            case "month":
                services.destination = .usage
                while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                // `month:last` opens the previous month, for captures early in a month.
                services.lookingBack = argument == "last"
                    ? MonthModel(month: Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
                    : MonthModel()
            case "othermac":
                // The sample Mac's own backup, opened as if it came from another Mac.
                let paths = services.snapshot.paths
                let archive = FileManager.default.temporaryDirectory.appendingPathComponent("bc-other-\(UUID().uuidString).aea")
                _ = await Task.detached {
                    _ = try? Backup.create(at: archive, password: "lamplight folio marginalia", paths: paths)
                    _ = try? OtherMacs.open(archive, password: "lamplight folio marginalia", name: "Studio", paths: paths)
                }.value
                services.refresh()
                while services.isLoading || !services.installs.contains(where: { $0.kind == .external(.otherMac) }) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let studio = services.installs.first(where: { $0.kind == .external(.otherMac) }) {
                    services.destination = .install(studio.id)
                }
            case "tomenubar":
                try? await Task.sleep(for: .seconds(2))
                AppDelegate.closeToMenuBar()
            case "secrets":
                services.destination = .secrets
            case "projects":
                // `projects:<name>` or `projects:<name>|<tab>`.
                let parts = argument.components(separatedBy: "|")
                UserDefaults.standard.set(parts.count == 2 ? parts[1] : "overview", forKey: "projectTab")
                let argument = parts[0]
                services.destination = .projects
                if !argument.isEmpty {
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    services.projectPages.load(index: services.index.index)
                    while !services.projectPages.loaded { try? await Task.sleep(for: .milliseconds(50)) }
                    services.projectPages.selectedID = services.projectPages.projects.first { $0.name == argument }?.id
                }
            case "subagents":
                UserDefaults.standard.set(true, forKey: "subagentsOpen")
                UserDefaults.standard.set(false, forKey: "flightRecorderOpen")
                services.destination = .conversations
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                }
            case "flight":
                // The reader with its cost and context chart open.
                UserDefaults.standard.set(true, forKey: "flightRecorderOpen")
                services.destination = .conversations
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                }
            case "reader":
                services.showsInspector = false
                // The panels a capture opened earlier stay closed here.
                UserDefaults.standard.set(false, forKey: "flightRecorderOpen")
                UserDefaults.standard.set(false, forKey: "subagentsOpen")
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
                // `install:<name>` or `install:<name>|<tab>`.
                let parts = argument.components(separatedBy: "|")
                if parts.count == 2 { UserDefaults.standard.set(parts[1], forKey: "installTab") }
                else { UserDefaults.standard.set("conversations", forKey: "installTab") }
                let argument = parts[0]
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
            case "running":
                services.destination = .running
            case "drift":
                // Claude Code's page, as if a newer Claude Code had renamed what file versions
                // and token usage are read from.
                var delta = FormatShape.Kind()
                delta.fields = ["type": ["string"], "path": ["string"], "backup": ["object"], "backup.version": ["int"],
                                "backup.backupFileName": ["null", "string"], "backup.backupTime": ["string"]]
                var assistant = FormatShape.Kind()
                assistant.fields = ["type": ["string"], "uuid": ["string"], "parentUuid": ["null", "string"],
                                    "sessionId": ["string"], "timestamp": ["string"], "cwd": ["string"],
                                    "message": ["object"], "message.id": ["string"], "message.model": ["string"],
                                    "message.content": ["array"], "message.usage": ["object"], "message.usage.input": ["int"],
                                    "message.usage.output_tokens": ["int"], "message.usage.cache_read_input_tokens": ["int"],
                                    "message.usage.cache_creation_input_tokens": ["int"]]
                let shape = FormatShape(format: "claude-code", version: "2.2.0",
                                        kinds: ["file-history-delta": delta, "assistant": assistant])
                services.formats.show(.init(contract: .claudeCode, shape: shape))
                if let install = services.installs.first(where: { $0.kind == .claudeCode }) {
                    services.destination = .install(install.id)
                }
            case "replay":
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    services.replaying = ReplayModel(conversation: match)
                }
            case "timelapse":
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    let model = TimelapseModel(conversation: match)
                    services.watching = model
                    // The last step: what the final turn changed.
                    while model.timelapse == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    model.step = max(0, (model.timelapse?.frames.count ?? 1) - 1)
                }
            case "rewind":
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    services.rewinding = RewindModel(conversation: match)
                }
            case "handoff":
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) {
                    services.selectedConversationID = match.id
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    services.beginHandoff(match)
                }
            case "prompts":
                services.destination = .prompts
            case "usage":
                services.destination = .usage
            case "files":
                services.destination = .files
                services.files.attach(services)
                while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                services.files.reload()
                while services.files.files.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                if !argument.isEmpty, let match = services.files.files.first(where: { $0.path.hasSuffix(argument) }) {
                    services.files.selectedPath = match.path
                }
            case "ask":
                services.destination = .ask
                if !argument.isEmpty {
                    services.ask.question = argument
                    while !services.index.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                    services.ask.ask(index: services.index.index)
                }
            case "library":
                services.destination = .library
                if let filter = LibraryFilter(rawValue: argument) { services.library.filter = filter }
                while services.library.summary == nil { try? await Task.sleep(for: .milliseconds(50)) }
                services.library.selectedID = services.library.visible.first?.id
                UserDefaults.standard.set(argument == "preview", forKey: "libraryPreview")
            case "panel":
                services.previewsMenuBarPanel = true
            case "palette":
                // `palette:<query>` over the first coding conversation, as if typed.
                services.destination = .conversations
                if let match = services.snapshot.conversations.first(where: { $0.title.localizedCaseInsensitiveContains("webhook") }) {
                    services.selectedConversationID = match.id
                }
                try? await Task.sleep(for: .milliseconds(600))
                services.paletteSeed = argument
                services.showsPalette = true
            case "gallery":
                services.previewsGallery = true
            case "history":
                services.destination = .history
            case "backup":
                services.destination = .kept
                services.pendingBackupSheet = true
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
            case "port":
                // `port:<name>`: moving a Cowork project into Claude Code.
                services.destination = .projects
                services.loadCoworkProjects()
                while services.coworkProjects.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                if let project = services.coworkProjects.first(where: { $0.name == argument }) {
                    services.beginPort(project)
                }
            case "copyproject":
                // `copyproject:<name>`: the sheet that copies a whole Cowork project.
                services.destination = .projects
                services.loadCoworkProjects()
                while services.coworkProjects.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                if let project = services.coworkProjects.first(where: { $0.name == argument }) {
                    services.beginProjectCopy(project)
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
                services.search.search(argument, immediately: true)
            default:
                break
            }
        }
        #endif
    }
}
