import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Where the main window is.
enum SidebarDestination: Hashable {
    case conversations
    case projects
    case running
    case ask
    case usage
    case files
    case prompts
    case library
    case install(String)
    case history
    case kept
    case storage
    case memory
    case secrets
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
    /// Debug builds only: shows the menu bar panel inside the window so it can be captured.
    var previewsMenuBarPanel = false

    let reader = ReaderModel()
    let index: IndexModel
    let pulse: PulseModel
    let spotlight = SpotlightIndexer()
    let recall: RecallModel
    let ask = AskModel()
    let usage = UsageModel()
    let files = FilesModel()
    let prompts = PromptsModel()
    let projectPages = ProjectsModel()
    let secrets = SecretsModel()
    let formats = FormatModel()
    let search: SearchModel
    let library = LibraryModel()
    let kept = KeptModel()
    let storage = StorageModel()
    let memory = MemoryModel()
    /// Bumped each time a fresh snapshot lands, so pages that derive from it know to redo
    /// their work.
    private(set) var generation = 0
    var errorMessage: String?


    private var loadTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var watchedRoots: [URL] = []
    private var observers: [NSObjectProtocol] = []

    init(paths: HostPaths = .current) {
        catalog = Catalog(paths: paths)
        index = IndexModel(paths: paths)
        search = SearchModel(history: index)
        pulse = PulseModel(paths: paths)
        recall = RecallModel(paths: paths)
        index.onUpdate = { [weak self] in
            guard let self else { return }
            search.refresh()
            spotlight.update(snapshot: snapshot, index: index.index)
            usage.refresh(snapshot: snapshot, index: index.index)
            coachLiveSessions()
        }
        usage.notifier = pulse.notifier
        pulse.notifier.onOpenConversation = { [weak self] id in
            guard let self, let conversation = snapshot.conversations.first(where: { $0.id == id }) else { return }
            NSApp.activate()
            show(conversation)
        }
        pulse.notifier.onOpenUsage = { [weak self] in
            NSApp.activate()
            self?.destination = .usage
        }
        pulse.notifier.onOpen = { [weak self] sessionID in
            guard let self else { return }
            if let session = pulse.sessions.first(where: { $0.sessionID == sessionID }), pulse.host(of: session) != nil {
                pulse.show(session)
            } else if let conversation = conversation(forSession: sessionID) {
                NSApp.activate()
                show(conversation)
            }
        }
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
            self.generation += 1
            self.isLoading = false
            self.hasLoaded = true
            self.updateRunning()
            self.index.update(from: fresh)
            self.pulse.start()
            self.recall.refresh(fresh)
            self.usage.start(self)
            self.watch(fresh)
            self.reopenIfChanged(fresh)
            if UserDefaults.standard.object(forKey: "keepAutomatically") as? Bool ?? true {
                self.kept.keep(fresh.conversations)
                // The same cleanup deletes the versions Claude Code saved of files, and plans.
                let paths = fresh.paths
                Task.detached(priority: .utility) {
                    KeptFileHistory.keep(configDirs: LiveSessions.configDirs(paths: paths), paths: paths)
                }
            }
            if let id = self.selectedConversationID, fresh.conversations.contains(where: { $0.id == id }) {
                // Still there; keep reading it.
            } else if self.selectedConversationID != nil {
                self.selectedConversationID = nil
            }
        }
    }

    /// Refreshes on its own when Claude writes a conversation, so the timeline is live.
    private func watch(_ snapshot: CatalogSnapshot) {
        let roots = DirectoryWatcher.conversationRoots(for: snapshot.installs, paths: snapshot.paths)
        guard roots != watchedRoots else { return }
        watcher?.stop()
        watchedRoots = roots
        watcher = DirectoryWatcher(roots: roots) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The open conversation grew while it was open: show the new messages.
    private func reopenIfChanged(_ snapshot: CatalogSnapshot) {
        guard let open = reader.conversation,
              let current = snapshot.conversations.first(where: { $0.id == open.id }),
              current.lastActivity != open.lastActivity || current.bytes != open.bytes else { return }
        reader.open(current, in: install(for: current), force: true)
    }

    private static let coachedKey = "contextNudgesSent"

    /// After each index pass: any running session that has read most of its context gets one
    /// heads-up per stretch.
    private func coachLiveSessions() {
        guard let history = index.index else { return }
        let live = pulse.sessions.compactMap { session -> ContextCoach.Live? in
            conversation(forSession: session.sessionID).map {
                ContextCoach.Live(sessionID: session.sessionID, conversationID: $0.id, project: session.projectName)
            }
        }
        guard !live.isEmpty else { return }
        let defaults = UserDefaults.standard
        Task {
            var sent = defaults.stringArray(forKey: Self.coachedKey) ?? []
            let nudges = (try? await ContextCoach.due(live, index: history, alreadySent: Set(sent))) ?? []
            for nudge in nudges {
                pulse.notifier.post(nudge)
                sent.append(nudge.key)
            }
            // A running session whose replies just changed model on their own.
            for session in live {
                let switches = (try? await ModelDrift.switches(conversationID: session.conversationID, index: history)) ?? []
                guard let latest = switches.last, latest.cause == .unexplained,
                      Date().timeIntervalSince(latest.at) < 20 * 60, !sent.contains("drift|" + latest.id) else { continue }
                pulse.notifier.post(drift: latest, project: session.project)
                sent.append("drift|" + latest.id)
            }
            defaults.set(Array(sent.suffix(300)), forKey: Self.coachedKey)
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
                case .claudeCode, .external: return nil
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

    /// Opens a `betterclaude://` link: `betterclaude://conversation/<session id>` opens
    /// that conversation, and `betterclaude://running` shows what's running.
    func open(_ url: URL) {
        guard url.scheme?.hasPrefix("betterclaude") == true else { return }
        switch url.host {
        case "conversation":
            let id = url.lastPathComponent
            if let conversation = snapshot.conversations.first(where: { $0.cliSessionId == id || $0.id == id }) {
                show(conversation)
            }
        case "running":
            destination = .running
        default:
            destination = .conversations
        }
    }

    func setShowsInSpotlight(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: SpotlightIndexer.enabledKey)
        if on { spotlight.update(snapshot: snapshot, index: index.index) } else { spotlight.clear() }
    }

    // MARK: Importing

    /// Asks for a claude.ai export and imports its conversations.
    func importClaudeWebExport() {
        let panel = NSOpenPanel()
        panel.message = "Choose the export claude.ai emailed you: the .zip, the folder it unpacks to, or its conversations.json."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .json, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let paths = snapshot.paths
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ClaudeWebImport.importExport(at: url, paths: paths) }
            }.value
            switch result {
            case .success(let report):
                let total = report.added + report.updated
                notice = total == 0
                    ? "Nothing new: every conversation in that export was already here."
                    : "Imported \(total) conversation\(total == 1 ? "" : "s") from claude.ai. They're in the timeline, and in search."
                refresh()
            case .failure(let error):
                errorMessage = String(describing: error)
            }
        }
    }

    /// A backup from another Mac, waiting for its password.
    var openingMac: OtherMacRequest?

    func openOtherMac() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Better Claude backup made on another Mac."
        panel.allowedContentTypes = [.init(filenameExtension: "aea") ?? .data]
        panel.directoryURL = Backup.iCloudFolder(paths: snapshot.paths)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openingMac = OtherMacRequest(backup: url)
    }

    func removeOtherMac(_ install: Install) {
        try? OtherMacs.remove(install.dataRoot)
        destination = .conversations
        refresh()
    }

    func removeClaudeWebImport() {
        do {
            try ClaudeWebImport.removeAll(paths: snapshot.paths)
            if case .install = destination { destination = .conversations }
            refresh()
        } catch {
            errorMessage = "Couldn't remove them: \(error.localizedDescription)"
        }
    }

    /// Debug builds only: opens the backup sheet on the Kept page, to capture it.
    var debugBackupSheet = false

    /// A one-line confirmation, shown as an alert.
    var notice: String?

    /// Shows a file's history on the Files page, even one Claude has only read.
    func showFile(_ path: String) {
        files.attach(self)
        destination = .files
        files.filter = ""
        files.selectedPath = path
    }

    /// Opens a conversation chosen in Spotlight.
    func openSpotlightItem(_ identifier: String) {
        if let conversation = snapshot.conversations.first(where: { $0.id == identifier }) {
            show(conversation)
        }
    }

    /// The conversation a Claude Code session is writing, by its session id.
    func conversation(forSession sessionID: String) -> ConversationRef? {
        snapshot.conversations.first { $0.cliSessionId == sessionID && !$0.isTranscriptMissing }
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
        guard !conversation.isTranscriptMissing, conversation.external == nil else { return }
        continuing = ContinueModel(conversation: conversation, source: install(for: conversation))
    }

    func endContinue() {
        continuing = nil
        refresh()
    }

    /// A replay being set up or run, as a sheet.
    var replaying: ReplayModel?
    var rewinding: RewindModel?
    var watching: TimelapseModel?
    var lookingBack: MonthModel?

    /// The handoff being written, as a sheet.
    var handingOff: HandoffModel?

    func beginHandoff(_ conversation: ConversationRef) {
        handingOff = HandoffModel(conversation: conversation)
    }

    /// Opens Terminal in `folder` and starts Claude Code with a handoff brief as its first
    /// message. The brief is saved beside Better Claude's other files and read from there, so
    /// nothing long goes through the shell.
    func startClaudeCode(in folder: String, brief: String, title: String) {
        let support = snapshot.paths.betterClaudeSupport
        let handoffs = support.appendingPathComponent("Handoffs", isDirectory: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let file = handoffs.appendingPathComponent("handoff-\(stamp).md")
        let script = support.appendingPathComponent("Resume/handoff-\(stamp).command")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let prompt = "Here is a handoff from an earlier conversation, \(title). Read it, then continue from where it left off:\n\n"
        let body = "#!/bin/zsh -l\ncd \(quoted(folder)) && exec claude \"$(cat \(quoted(file.path)))\"\n"
        do {
            try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((prompt + brief).utf8).write(to: file, options: .atomic)
            try Data(body.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = "Couldn't open Terminal: \(error.localizedDescription)"
        }
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

