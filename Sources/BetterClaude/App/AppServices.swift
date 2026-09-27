import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Where the main window is.
enum SidebarDestination: Hashable {
    case conversations
    case library
    case install(String)
    case history
}

/// Narrows the conversation timeline to one install or one project folder.
enum ConversationFilter: Hashable {
    case all
    case install(String)
    case project(String)
}

/// The app's one shared model. It owns the catalog of everything on the Mac and the state
/// every window reads from; the heavy lifting happens in the engine, off the main actor.
@MainActor
@Observable
final class AppServices {
    let catalog: Catalog
    private(set) var snapshot = CatalogSnapshot()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Installs whose app is open right now, by install id.
    private(set) var running: Set<String> = []

    var destination: SidebarDestination? = .conversations
    var filter: ConversationFilter = .all
    var selectedConversationID: String? {
        didSet { if selectedConversationID != oldValue { openSelected() } }
    }
    var query = ""

    let reader = ReaderModel()
    let search = SearchModel()
    var errorMessage: String?

    /// The previous app model, still behind Library, the install pages' setup lists, and the
    /// transfer sheet while those are rebuilt.
    let legacy = AppModel()

    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(paths: HostPaths = .current) {
        catalog = Catalog(paths: paths)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
    }

    // MARK: Loading

    /// Re-reads the machine. Cheap to call often: unchanged transcripts are not read again.
    func refresh() {
        loadTask?.cancel()
        isLoading = true
        setup = [:]
        credentialHints = [:]
        loadTask = Task { [catalog] in
            let fresh = await catalog.snapshot()
            guard !Task.isCancelled else { return }
            self.snapshot = fresh
            self.isLoading = false
            self.hasLoaded = true
            self.updateRunning()
            self.search.invalidate()
            if let id = self.selectedConversationID, fresh.conversations.contains(where: { $0.id == id }) {
                // Still there; keep reading it.
            } else if self.selectedConversationID != nil {
                self.selectedConversationID = nil
            }
        }
    }

    func updateRunning() {
        let installs = snapshot.installs
        Task.detached(priority: .utility) {
            let variants = (try? Guards.runningVariants()) ?? []
            let open = Set(variants.map { $0.userDataDir.standardizedFileURL.path })
            let science = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == InstallDiscovery.scienceBundleIdentifier
            }
            let ids = Set(installs.compactMap { install -> String? in
                switch install.kind {
                case .science: return science ? install.id : nil
                case .claudeCode: return nil
                case .desktop, .parallex:
                    return open.contains(install.dataRoot.standardizedFileURL.path) ? install.id : nil
                }
            })
            await MainActor.run { self.running = ids }
        }
    }

    // MARK: Conversations

    var installs: [Install] { snapshot.installs }

    func install(_ id: String) -> Install? { snapshot.install(id) }

    func install(for conversation: ConversationRef) -> Install? { snapshot.install(conversation.installID) }

    func isRunning(_ install: Install) -> Bool { running.contains(install.id) }

    func conversationCount(in install: Install) -> Int {
        snapshot.conversations.lazy.filter { $0.installID == install.id }.count
    }

    /// The timeline as filtered and searched.
    var visibleConversations: [ConversationRef] {
        var list = snapshot.conversations.filter { !$0.isArchived }
        switch filter {
        case .all: break
        case .install(let id): list = list.filter { $0.installID == id }
        case .project(let path): list = list.filter { $0.projectPath == path }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return list }
        return list.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(needle)
                || (conversation.projectName?.localizedCaseInsensitiveContains(needle) ?? false)
                || (install(for: conversation)?.name.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var selectedConversation: ConversationRef? {
        selectedConversationID.flatMap { id in snapshot.conversations.first { $0.id == id } }
    }

    /// Project folders that have conversations, most active first — the choices in the filter.
    var projects: [(path: String, name: String, count: Int)] {
        let grouped = Dictionary(grouping: snapshot.conversations.compactMap(\.projectPath), by: { $0 })
        return grouped.map { (path: $0.key, name: URL(fileURLWithPath: $0.key).lastPathComponent,
                              count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    var filterTitle: String {
        switch filter {
        case .all: return "All conversations"
        case .install(let id): return install(id)?.name ?? "Conversations"
        case .project(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func show(_ conversation: ConversationRef) {
        destination = .conversations
        if !visibleConversations.contains(where: { $0.id == conversation.id }) {
            filter = .all
            query = ""
        }
        selectedConversationID = conversation.id
    }

    private func openSelected() {
        guard let conversation = selectedConversation else {
            reader.close()
            return
        }
        reader.open(conversation, in: install(for: conversation))
    }

    // MARK: Carrying a conversation elsewhere

    /// The conversation being continued elsewhere, shown as a sheet.
    var continuing: ContinueModel?

    func beginContinue(_ conversation: ConversationRef) {
        guard !conversation.isTranscriptMissing else { return }
        continuing = ContinueModel(conversation: conversation, source: install(for: conversation))
    }

    func endContinue() {
        continuing = nil
        refresh()
    }

    /// Opens Terminal in `cwd` and resumes a Claude Code conversation there.
    ///
    /// A `.command` file rather than scripting Terminal: opening a file needs no permission,
    /// where telling Terminal what to run asks for control of it.
    func resumeInTerminal(cwd: String, sessionId: String) {
        let folder = snapshot.paths.betterClaudeSupport.appendingPathComponent("Resume", isDirectory: true)
        let script = folder.appendingPathComponent("resume-\(sessionId.prefix(8)).command")
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/zsh -l\ncd \(quoted) && exec claude --resume \(sessionId)\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    // MARK: Setup

    /// What each install is set up with, by install id; filled on first look.
    private(set) var setup: [String: [ConfigItem]] = [:]
    private(set) var credentialHints: [String: [CredentialHints.Hint]] = [:]

    func loadSetup(for install: Install) {
        guard setup[install.id] == nil else { return }
        Task {
            let (items, hints) = await Task.detached(priority: .userInitiated) {
                (ConfigInventory.items(for: install), CredentialHints.hints(for: install))
            }.value
            setup[install.id] = items
            credentialHints[install.id] = hints
        }
    }

    /// The comparison on screen, as a sheet.
    var comparing: InstallComparison?

    // MARK: Forking

    /// A fork being set up, shown as a sheet.
    var forking: ForkRequest?

    func fork(_ request: ForkRequest, title: String) async {
        do {
            let url = try await reader.fork(at: request.messageID, title: title)
            forking = nil
            refresh()
            // Open the fork once the catalog has it.
            while isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            if let fork = snapshot.conversations.first(where: { $0.transcriptURL?.standardizedFileURL == url.standardizedFileURL }) {
                show(fork)
            }
        } catch {
            forking = nil
            errorMessage = "Couldn't fork it: \(ContinueModel.explain(error))"
        }
    }

    // MARK: Actions

    func open(_ install: Install) {
        guard let app = install.appURL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ conversation: ConversationRef) {
        let url = conversation.transcriptURL ?? conversation.coworkSession?.metadataURL
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

