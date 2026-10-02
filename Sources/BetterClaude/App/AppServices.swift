import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Where the main window is.
enum SidebarDestination: Hashable {
    case home
    case thisMac
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

/// A place in the window: a page and what was selected on it, so going back returns to
/// exactly where you were.
struct Place: Equatable {
    var destination: SidebarDestination?
    var filter: ConversationFilter
    var conversationID: String?
    var projectID: String?
}

/// Narrows the conversation timeline to one install or one project folder, or shows the
/// archived conversations, which every other list and count leaves out.
enum ConversationFilter: Hashable {
    case all
    case install(String)
    case project(String)
    case archived

    func includes(_ conversation: ConversationRef) -> Bool {
        guard conversation.isArchived == (self == .archived) else { return false }
        switch self {
        case .all, .archived: return true
        case .install(let id): return conversation.installID == id
        // Grouped the way the Projects page groups them, so worktrees count as their repository.
        case .project(let path): return conversation.projectPath.map(Projects.root(of:)) == path
        }
    }
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

    var destination: SidebarDestination? = .home {
        didSet {
            guard destination != oldValue, !restoringPlace else { return }
            remember(Place(destination: oldValue, filter: filter, conversationID: selectedConversationID,
                           projectID: projectPages.selectedID))
        }
    }

    // MARK: Back and forward

    private(set) var backPlaces: [Place] = []
    private(set) var forwardPlaces: [Place] = []
    private var restoringPlace = false

    var currentPlace: Place {
        Place(destination: destination, filter: filter, conversationID: selectedConversationID,
              projectID: projectPages.selectedID)
    }

    /// Opens a project's page, or the list of them, so Back returns to where you were.
    func openProject(_ id: String?) {
        guard id != projectPages.selectedID else { return }
        remember(currentPlace)
        projectPages.selectedID = id
    }

    /// Starts a new Claude Code session in a folder, in Terminal.
    func newSession(in folder: String) {
        let support = snapshot.paths.betterClaudeSupport
        let script = support.appendingPathComponent("Resume/new-\(Int(Date().timeIntervalSince1970)).command")
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/zsh -l\ncd \(quoted) && exec claude\n".utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    private func remember(_ place: Place) {
        if backPlaces.last != place { backPlaces.append(place) }
        if backPlaces.count > 50 { backPlaces.removeFirst(backPlaces.count - 50) }
        forwardPlaces.removeAll()
    }

    func goBack() {
        guard let place = backPlaces.popLast() else { return }
        forwardPlaces.append(currentPlace)
        restore(place)
    }

    func goForward() {
        guard let place = forwardPlaces.popLast() else { return }
        backPlaces.append(currentPlace)
        restore(place)
    }

    private func restore(_ place: Place) {
        restoringPlace = true
        defer { restoringPlace = false }
        destination = place.destination
        filter = place.filter
        projectPages.selectedID = place.projectID
        selectedConversationID = place.conversationID
    }
    var filter: ConversationFilter = .all {
        didSet {
            // The open conversation goes when the new filter leaves it out of the list.
            guard filter != oldValue, let open = selectedConversation, !filter.includes(open) else { return }
            selectedConversationID = nil
        }
    }
    var selectedConversationID: String? {
        didSet { if selectedConversationID != oldValue { openSelected() } }
    }
    var query = ""
    /// Debug builds only: shows the menu bar panel inside the window so it can be captured.
    var previewsMenuBarPanel = false
    /// Debug builds: the component gallery instead of a page.
    var previewsGallery = false

    let reader = ReaderModel()
    let index: IndexModel
    let pulse: PulseModel
    let spotlight = SpotlightIndexer()
    let recall: RecallModel
    let ask = AskModel()
    let home = HomeModel()
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
    private var refreshQueued = false
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
        watchCaches()
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
    /// A call while a read is under way asks for one more read after it, so a stream of
    /// changes never starves the read that's nearly done.
    func refresh() {
        guard loadTask == nil else {
            refreshQueued = true
            return
        }
        isLoading = true
        loadTask = Task { [catalog] in
            let fresh = await catalog.snapshot()
            self.loadTask = nil
            self.snapshot = fresh
            self.generation += 1
            self.hasLoaded = true
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            } else {
                self.isLoading = false
            }
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
            + [CodexSessions.home(paths: snapshot.paths).appendingPathComponent("sessions", isDirectory: true)]
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
    private var cacheWatch: Timer?

    /// Every half minute: a session waiting on you whose cache goes cold in under two minutes
    /// gets one heads-up, when its conversation is big enough for that to cost something.
    func watchCaches() {
        guard cacheWatch == nil else { return }
        cacheWatch = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCaches() }
        }
    }

    /// Background jobs that ended, failed or stalled in the last two hours, told once each.
    private func checkJobs() {
        let paths = snapshot.paths
        Task {
            let jobs = await Task.detached { Unattended.jobs(configDirs: LiveSessions.configDirs(paths: paths)) }.value
            var sent = UserDefaults.standard.stringArray(forKey: Self.coachedKey) ?? []
            for job in jobs where job.outcome != .running {
                guard let updated = job.updated, Date().timeIntervalSince(updated) < 2 * 3_600 else { continue }
                let key = "job|\(job.id)|\(job.outcome.rawValue)"
                guard !sent.contains(key) else { continue }
                pulse.notifier.post(job: job)
                sent.append(key)
            }
            UserDefaults.standard.set(Array(sent.suffix(300)), forKey: Self.coachedKey)
        }
    }

    private func checkCaches() {
        checkJobs()
        guard let history = index.index else { return }
        let waiting = pulse.sessions.filter { $0.state != .working }.compactMap { session -> (LiveSession, ConversationRef)? in
            conversation(forSession: session.sessionID).map { (session, $0) }
        }
        guard !waiting.isEmpty else { return }
        Task {
            var sent = UserDefaults.standard.stringArray(forKey: Self.coachedKey) ?? []
            for (session, conversation) in waiting {
                guard let cache = try? await CacheBreaks.expiry(conversationID: conversation.id, index: history),
                      cache.context >= 80_000 else { continue }
                let left = cache.at.timeIntervalSinceNow
                let key = "cache|\(conversation.id)|\(Int(cache.at.timeIntervalSince1970))"
                guard left > 0, left <= 120, !sent.contains(key) else { continue }
                pulse.notifier.post(cacheExpiring: session.projectName, conversationID: conversation.id,
                                    minutes: max(1, Int((left / 60).rounded(.up))), context: cache.context,
                                    extra: cache.extra, key: key)
                sent.append(key)
            }
            UserDefaults.standard.set(Array(sent.suffix(300)), forKey: Self.coachedKey)
        }
    }

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
                    if open.contains(install.dataRoot.standardizedFileURL.path) { return install.id }
                    // A copy Launch Services lost track of still holds its store's lock.
                    return ((try? Guards.holders(ofStore: install.dataRoot)) ?? []).isEmpty ? nil : install.id
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

    /// An install's conversations as counted everywhere: archived ones left out.
    func conversationCount(in install: Install) -> Int {
        snapshot.conversations.lazy.filter { $0.installID == install.id && !$0.isArchived }.count
    }

    /// Conversations you've archived, reachable from the filter.
    var archivedCount: Int { snapshot.conversations.lazy.filter(\.isArchived).count }

    /// The newest conversations worth picking up again, for Home and the palette.
    func recentConversations(_ count: Int) -> [ConversationRef] {
        Array(snapshot.conversations
            .filter { !$0.isArchived && !$0.isTranscriptMissing }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(count))
    }

    /// Shows the timeline narrowed to `filter`, so Back returns to where you were.
    func showConversations(_ filter: ConversationFilter) {
        if destination != .conversations {
            // Changing page records the place you left, so before the filter changes.
            destination = .conversations
        } else if filter != self.filter {
            remember(currentPlace)
        }
        self.filter = filter
    }

    /// The timeline as filtered and searched.
    var visibleConversations: [ConversationRef] {
        let filter = filter
        let list = snapshot.conversations.filter { filter.includes($0) }
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
            destination = .home
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

    /// The command palette, over the window.
    var showsPalette = false

    /// What the toolbar says beside back and forward. Pages with their own big title say nothing.
    var windowTitle: String {
        switch destination {
        case .conversations, nil: return filterTitle
        case .library: return "Library"
        case .projects:
            return projectPages.selectedID.flatMap { id in projectPages.projects.first { $0.id == id }?.name } ?? ""
        default: return ""
        }
    }
    /// The reader's inspector, and which tab it shows. Both are remembered.
    var showsInspector = UserDefaults.standard.object(forKey: "showsInspector") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") }
    }
    var inspectorTab = InspectorTab(rawValue: UserDefaults.standard.string(forKey: "inspectorTab") ?? "") ?? .info {
        didSet { UserDefaults.standard.set(inspectorTab.rawValue, forKey: "inspectorTab") }
    }
    /// Text the palette opens with (debug captures).
    var paletteSeed = ""

    /// Asks the model built into macOS about your history, on the Ask page.
    func askHistory(_ question: String) {
        query = ""
        destination = .ask
        ask.question = question
        ask.ask(index: index.index)
    }

    /// Opens the backup sheet when the Kept page appears (the palette, and debug captures).
    var pendingBackupSheet = false

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
        let paths = snapshot.conversations.filter { !$0.isArchived }.compactMap { $0.projectPath.map(Projects.root(of:)) }
        let grouped = Dictionary(grouping: paths, by: { $0 })
        return grouped.map { (path: $0.key, name: URL(fileURLWithPath: $0.key).lastPathComponent,
                              count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    var filterTitle: String {
        switch filter {
        case .all: return "All conversations"
        case .install(let id): return install(id)?.name ?? "Conversations"
        case .project(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .archived: return "Archived"
        }
    }

    /// Opens a conversation in the timeline, widening the filter and clearing the search when
    /// they would hide it.
    func show(_ conversation: ConversationRef) {
        destination = .conversations
        if !visibleConversations.contains(where: { $0.id == conversation.id }) {
            filter = conversation.isArchived ? .archived : .all
            query = ""
        }
        selectedConversationID = conversation.id
    }

    /// Opens the conversation with this id, if it's on the Mac.
    func show(conversationID id: String) {
        if let conversation = snapshot.conversations.first(where: { $0.id == id }) { show(conversation) }
    }

    /// Where the sidebar and ⌘1–⌘6 go. Asking for the page you're on goes back to its top:
    /// Projects returns to the list of projects.
    func go(to page: SidebarDestination) {
        if page == .projects, destination == .projects, projectPages.selectedID != nil {
            openProject(nil)
        } else {
            destination = page
        }
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

    /// Cowork projects with at least one conversation, across every install.
    private(set) var coworkProjects: [CoworkProject] = []

    func loadCoworkProjects() {
        let sessions = snapshot.conversations.compactMap(\.coworkSession)
        Task {
            let projects = await Task.detached(priority: .utility) { CoworkProjects.projects(in: sessions) }.value
            coworkProjects = projects
        }
    }

    /// The project a Cowork conversation belongs to, once projects have been read.
    func coworkProject(for conversation: ConversationRef) -> CoworkProject? {
        guard let session = conversation.coworkSession else { return nil }
        return coworkProjects.first { $0.sessions.contains { $0.metadataURL == session.metadataURL } }
    }

    /// Copy a whole Cowork project, every conversation in it, into another Claude.
    func beginProjectCopy(_ project: CoworkProject) {
        let paths = Set(project.sessions.map(\.metadataURL))
        let conversations = snapshot.conversations.filter {
            guard let session = $0.coworkSession else { return false }
            return paths.contains(session.metadataURL) && !$0.isTranscriptMissing
        }
        guard let first = conversations.first else { return }
        continuing = ContinueModel(project: project, conversations: conversations, source: install(for: first))
    }

    /// A Cowork project being moved into Claude Code, as a sheet.
    var porting: PortModel?

    func beginPort(_ project: CoworkProject) {
        // The Code tab of the Claude the project came from, when it has one.
        let source = installs.first { install in
            (snapshot.accounts[install.id] ?? []).contains { $0.id == project.account.id }
        }
        porting = PortModel(project: project,
                            codeTabInstallID: source.flatMap { $0.codeTabRoot == nil ? nil : $0.id })
    }

    func endPort() {
        porting = nil
        refresh()
    }

    /// Terminal in `folder`, showing Claude Code's list of conversations to resume there.
    func resumePicker(in folder: String) {
        let support = snapshot.paths.betterClaudeSupport
        let script = support.appendingPathComponent("Resume/resume-\(Int(Date().timeIntervalSince1970)).command")
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/zsh -l\ncd \(quoted) && exec claude --resume\n".utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

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

    /// What each install is set up with, by install id; filled on first look. What was read
    /// stays on screen until a newer read replaces it.
    private(set) var setup: [String: [ConfigItem]] = [:]
    private(set) var credentialHints: [String: [CredentialHints.Hint]] = [:]
    private var setupGeneration: [String: Int] = [:]
    private var readingSetup: Set<String> = []

    /// Reads an install's setup again when the machine has been re-read since.
    func loadSetup(for install: Install) {
        let id = install.id
        guard !readingSetup.contains(id), setupGeneration[id] != generation || setup[id] == nil else { return }
        readingSetup.insert(id)
        let generation = generation
        Task {
            let (items, hints) = await Task.detached(priority: .userInitiated) {
                (ConfigInventory.items(for: install), CredentialHints.hints(for: install))
            }.value
            setup[id] = items
            credentialHints[id] = hints
            setupGeneration[id] = generation
            readingSetup.remove(id)
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

