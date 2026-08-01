import AppKit
import CoworkKit
import Foundation
import Observation

/// A source of sessions in the sidebar.
enum Source: Hashable, Identifiable {
    case coworkAccount(AccountRef)
    case claudeCodeProject(URL)

    var id: String {
        switch self {
        case .coworkAccount(let a): return "cowork:\(a.id)"
        case .claudeCodeProject(let u): return "code:\(u.path)"
        }
    }
}

/// One entry in the sidebar, flattened so both source kinds render identically.
struct SidebarItem: Identifiable {
    let source: Source
    let title: String
    let symbol: String
    let badge: String?
    /// Projects put their parent folder in the badge slot rather than a count, which needs
    /// more room than two digits.
    let badgeIsWide: Bool
    let help: String

    var id: String { source.id }
}

/// One row in the session list, flattened so both session kinds render identically.
struct SessionRow: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let date: Date
    let byteSize: Int64
    let hasTranscript: Bool
    /// Short, human form shown in its own column: "Sonnet 4.6" rather than
    /// "claude-sonnet-4-6".
    let modelName: String
    let cowork: SessionRef?
    let claudeCode: CCSessionRef?

    init(_ session: SessionRef) {
        id = session.sessionId
        title = session.title.isEmpty ? "(untitled)" : session.title
        subtitle = session.model + (session.isArchived ? " · archived" : "")
        modelName = Self.humanModel(session.model) + (session.isArchived ? " · archived" : "")
        date = session.lastActivityAt
        byteSize = session.byteSize
        hasTranscript = session.transcriptURL != nil
        cowork = session
        claudeCode = nil
    }

    init(_ session: CCSessionRef) {
        id = session.sessionId
        title = session.title.isEmpty ? "(untitled)" : session.title
        subtitle = "\(session.recordCount) records"
        modelName = "\(session.recordCount) msgs"
        date = session.lastTimestamp
        byteSize = session.byteSize
        hasTranscript = true
        cowork = nil
        claudeCode = session
    }

    /// `claude-opus-4-8[1m]` → `Opus 4.8`. Unrecognised identifiers pass through unchanged
    /// rather than being mangled, since the set of model names keeps growing.
    static func humanModel(_ raw: String) -> String {
        var name = raw
        if let bracket = name.firstIndex(of: "[") { name = String(name[name.startIndex..<bracket]) }
        guard name.hasPrefix("claude-") else { return raw }
        let parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = parts.first else { return raw }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

/// The app's top-level pillars. Each answers a different question about a Claude install,
/// so they are peers in the sidebar rather than modes hidden behind a menu.
enum Pane: String, CaseIterable, Identifiable {
    case conversations, control, library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversations: return "Conversations"
        case .control: return "Control"
        case .library: return "Library"
        }
    }

    var summary: String {
        switch self {
        case .conversations: return "Move, read and search what you and Claude have said"
        case .control: return "Skills, servers, agents and memory across every install"
        case .library: return "Everything Claude has made for you"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var pane: Pane = .conversations

    // MARK: - Control

    var configScopes: [ConfigScope] = []
    var configItems: [ConfigItem] = []
    var comparison: ConfigComparison?
    var configScopeFilter: ConfigScope?

    /// Scopes that actually hold something. Three installs on a typical machine have a
    /// config directory but nothing in it; listing them invites a click that lands nowhere.
    var populatedConfigScopes: [ConfigScope] {
        let counts = Dictionary(grouping: configItems, by: \.scope).mapValues(\.count)
        return configScopes.filter { (counts[$0] ?? 0) > 0 }
    }
    var isLoadingConfig = false

    /// Off the main actor: a full inventory walks every skill, plugin and settings file on
    /// the machine and takes well over a second, which freezes the window if run inline.
    func loadConfig() async {
        guard !isLoadingConfig else { return }
        isLoadingConfig = true
        defer { isLoadingConfig = false }
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([ConfigScope], [ConfigItem])? in
            guard let scopes = try? ConfigInventory.scopes(),
                  let items = try? ConfigInventory.everything() else { return nil }
            return (scopes, items)
        }.value
        guard let loaded else {
            errorMessage = "Configuration could not be read."
            return
        }
        configScopes = loaded.0
        configItems = loaded.1
    }

    // MARK: - Branch

    struct Branching {
        let row: SessionRow
        let transcript: Transcript
        let points: [BranchPoint]
        let totalMessages: Int
    }

    var branching: Branching?
    var branchPoint: BranchPoint?
    var branchTitle = ""

    /// Only Claude Code conversations can be branched in place.
    ///
    /// A branch is a new transcript beside the original, which is exactly what makes a
    /// Claude Code session — its store lists `<projectDir>/<uuid>.jsonl` directly. A Cowork
    /// session is a metadata file plus a workspace, so a bare transcript there would sit on
    /// disk unlisted. That path goes through Transfer instead, and is not pretended here.
    func canBranch(_ row: SessionRow) -> Bool { row.claudeCode != nil }

    func openBranch(_ row: SessionRow) {
        guard let url = row.claudeCode?.transcriptURL else {
            errorMessage = "Only Claude Code conversations can be branched in place. "
                + "Transfer a Cowork conversation to a project first."
            return
        }
        guard let transcript = try? Transcript(contentsOf: url) else {
            errorMessage = "That conversation's transcript could not be read."
            return
        }
        let points = ConversationBranch.points(in: transcript)
        guard !points.isEmpty else {
            errorMessage = "That conversation has no message to branch from."
            return
        }
        branchTitle = "\(row.title) — branch"
        branchPoint = nil
        branching = Branching(row: row, transcript: transcript, points: points,
                              totalMessages: ConversationText.messages(in: transcript).count)
    }

    func cancelBranch() {
        branching = nil
        branchPoint = nil
    }

    func applyBranch() {
        guard let branching, let point = branchPoint else { return }
        do {
            let (plan, branched) = try ConversationBranch.plan(
                transcript: branching.transcript, cutAt: point,
                newTitle: branchTitle.isEmpty ? nil : branchTitle)
            guard !FileManager.default.fileExists(atPath: plan.destinationURL.path) else {
                errorMessage = "A conversation with that id already exists."
                return
            }
            try branched.write(to: plan.destinationURL)
            statusMessage = "Branched \(plan.keptRecords) records into a new conversation."
            cancelBranch()
            loadSessions()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Library

    var harvest: HarvestSummary?
    var isHarvesting = false
    var libraryQuery = ""
    var libraryKind: ArtifactKind?
    var selectedArtifact: Artifact?

    /// Walks every conversation's transcript and workspace. Off the main actor for the same
    /// reason the search index is: this reads hundreds of megabytes.
    func runHarvest() async {
        guard !isHarvesting else { return }
        isHarvesting = true
        defer { isHarvesting = false }

        struct Source: Sendable {
            let transcript: URL
            let workspace: URL?
            let title: String
            let id: String
            let container: String
        }
        var sources: [Source] = []
        for store in stores {
            for account in accounts[store] ?? [] {
                for session in (try? Discovery.sessions(in: account)) ?? [] {
                    guard let url = session.transcriptURL else { continue }
                    sources.append(Source(transcript: url, workspace: session.workspaceURL,
                                          title: session.title, id: session.sessionId,
                                          container: store.variantDirName))
                }
            }
        }
        for dir in claudeCodeProjects {
            for session in (try? Discovery.claudeCodeSessions(projectDir: dir,
                                                              configDir: claudeCodeConfigDir)) ?? [] {
                sources.append(Source(transcript: session.transcriptURL, workspace: nil,
                                      title: session.title, id: session.sessionId,
                                      container: projectLabel(dir)))
            }
        }

        let captured = sources
        harvest = await Task.detached(priority: .userInitiated) { () -> HarvestSummary in
            var all: [Artifact] = []
            var scanned = 0
            let skipped: [String] = []
            for source in captured {
                scanned += 1
                if let transcript = try? Transcript(contentsOf: source.transcript) {
                    all += ArtifactHarvest.codeBlocks(in: transcript,
                                                      conversationTitle: source.title,
                                                      conversationID: source.id,
                                                      container: source.container)
                }
                if let workspace = source.workspace {
                    all += ArtifactHarvest.files(inWorkspace: workspace,
                                                 conversationTitle: source.title,
                                                 conversationID: source.id,
                                                 container: source.container)
                }
            }
            let (kept, collapsed) = ArtifactHarvest.deduplicate(all)
            return HarvestSummary(artifacts: kept,
                                  totalBytes: kept.reduce(0) { $0 + Int64($1.bytes) },
                                  duplicatesCollapsed: collapsed,
                                  conversationsScanned: scanned,
                                  skipped: skipped)
        }.value
    }

    func revealArtifact(_ artifact: Artifact) {
        if let url = artifact.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let match = rows.first(where: { $0.id == artifact.conversationID }) {
            pane = .conversations
            openForReading(match)
        }
    }

    func copyArtifact(_ artifact: Artifact) {
        let text: String?
        if let inline = artifact.inlineContent {
            text = inline
        } else if let url = artifact.fileURL {
            text = try? String(contentsOf: url, encoding: .utf8)
        } else {
            text = nil
        }
        guard let text else {
            errorMessage = "That artifact's content could not be read."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func compareScopes(_ left: ConfigScope, _ right: ConfigScope) {
        do {
            comparison = try ConfigDiff.compare(left, right)
        } catch {
            errorMessage = "\(error)"
        }
    }

    var stores: [StoreRef] = []
    var accounts: [StoreRef: [AccountRef]] = [:]
    var claudeCodeProjects: [URL] = []
    var runningVariants: [RunningVariant] = []

    var selectedSource: Source?
    var rows: [SessionRow] = []
    var selectedRowIDs: Set<String> = []

    var isLoading = false
    var errorMessage: String?
    var statusMessage: String?

    let claudeCodeConfigDir = Discovery.defaultClaudeCodeConfigDir()

    var selectedRows: [SessionRow] { rows.filter { selectedRowIDs.contains($0.id) } }

    // MARK: - Reading a conversation

    struct Reading {
        let row: SessionRow
        let messages: [MessageText]
        let transcript: Transcript
        let subtitle: String
    }

    var reading: Reading?

    func openForReading(_ row: SessionRow) {
        let url = row.cowork?.transcriptURL ?? row.claudeCode?.transcriptURL
        guard let url, let transcript = try? Transcript(contentsOf: url) else {
            errorMessage = "That conversation's transcript could not be read."
            return
        }
        let messages = ConversationText.messages(in: transcript)
        // `modelName` is a record count for Claude Code rows, so including it here printed
        // two disagreeing counts of the same conversation.
        let facts = [row.cowork == nil ? nil : row.modelName,
                     "\(messages.count) message\(messages.count == 1 ? "" : "s")",
                     row.date.compactStamp].compactMap { $0 }
        reading = Reading(row: row, messages: messages, transcript: transcript,
                          subtitle: facts.joined(separator: " · "))
    }

    func closeReading() { reading = nil }

    /// Writes the open conversation to a file the user chooses.
    func exportOpenConversation() {
        guard let reading else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExport.suggestedFileName(for: reading.row.title)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let markdown = MarkdownExport.render(transcript: reading.transcript,
                                             title: reading.row.title,
                                             model: reading.row.modelName)
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: - Search across everything

    private let index = SearchIndex()
    var isIndexing = false
    var indexedConversations = 0
    var globalHits: [SearchHit] = []
    var globalQuery = ""
    var isSearchingEverywhere = false

    /// Reads every transcript on the machine once and keeps the prose in memory.
    ///
    /// Transcripts run to tens of megabytes each and the parse is the expensive part, so the
    /// work happens off the main actor and the finished entries are handed to the index in
    /// one go rather than trickling in and re-rendering the list on every file.
    func buildIndexIfNeeded() async {
        guard !isIndexing, await !index.isBuilt else { return }
        isIndexing = true
        defer { isIndexing = false }

        var sources: [(ConversationLocation, String, Date)] = []
        for store in stores {
            for account in accounts[store] ?? [] {
                for session in (try? Discovery.sessions(in: account)) ?? [] {
                    guard let url = session.transcriptURL else { continue }
                    sources.append((
                        ConversationLocation(kind: .cowork, container: store.variantDirName,
                                             identity: account.emailAddress, transcriptURL: url,
                                             rowID: session.sessionId),
                        session.title, session.lastActivityAt))
                }
            }
        }
        for projectDir in claudeCodeProjects {
            for session in (try? Discovery.claudeCodeSessions(projectDir: projectDir,
                                                              configDir: claudeCodeConfigDir)) ?? [] {
                sources.append((
                    ConversationLocation(kind: .claudeCode,
                                         container: projectLabel(projectDir),
                                         identity: projectPath(projectDir),
                                         transcriptURL: session.transcriptURL,
                                         rowID: session.sessionId),
                    session.title, session.lastTimestamp))
            }
        }

        // Parsing is the whole cost here — several hundred megabytes of JSONL, with single
        // transcripts running past 100 MB — and it is embarrassingly parallel, so it is
        // spread across cores rather than walked one file at a time.
        let entries: [SearchIndex.Entry] = await withTaskGroup(of: SearchIndex.Entry?.self) { group in
            let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
            var iterator = sources.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let next = iterator.next() else { return }
                inFlight += 1
                group.addTask(priority: .userInitiated) {
                    try? SearchIndex.makeEntry(location: next.0, title: next.1, lastActivity: next.2)
                }
            }
            for _ in 0..<limit { addNext() }

            var built: [SearchIndex.Entry] = []
            built.reserveCapacity(sources.count)
            while inFlight > 0, let finished = await group.next() {
                inFlight -= 1
                if let finished { built.append(finished) }
                addNext()
            }
            return built
        }

        await index.replaceAll(with: entries)
        indexedConversations = entries.count
    }

    func searchEverywhere(_ query: String) async {
        globalQuery = query
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            globalHits = []
            isSearchingEverywhere = false
            return
        }
        isSearchingEverywhere = true
        await buildIndexIfNeeded()
        globalHits = await index.search(query)
    }

    func exitGlobalSearch() {
        isSearchingEverywhere = false
        globalHits = []
        globalQuery = ""
    }

    /// Jump to the conversation a search hit belongs to.
    func reveal(_ hit: SearchHit) {
        switch hit.location.kind {
        case .cowork:
            let match = stores.flatMap { accounts[$0] ?? [] }.first { account in
                (try? Discovery.sessions(in: account))?.contains { $0.sessionId == hit.id } ?? false
            }
            if let match { selectedSource = .coworkAccount(match) }
        case .claudeCode:
            if let dir = claudeCodeProjects.first(where: { projectPath($0) == hit.location.identity }) {
                selectedSource = .claudeCodeProject(dir)
            }
        }
        exitGlobalSearch()
        loadSessions()
        selectedRowIDs = [hit.id]
    }

    /// True when the app that owns `store` is running, which makes the store unsafe to write.
    func isRunning(_ store: StoreRef) -> Bool {
        runningVariants.contains { $0.userDataDir.standardizedFileURL == store.userDataDir.standardizedFileURL }
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        do {
            stores = try Discovery.stores()
            accounts = [:]
            for store in stores {
                accounts[store] = try Discovery.accounts(in: store)
            }
            runningVariants = (try? Guards.runningVariants()) ?? []
            claudeCodeProjects = (try? Discovery.claudeCodeProjects(configDir: claudeCodeConfigDir)) ?? []
            resolveProjectPaths()
            if selectedSource == nil {
                selectedSource = accounts.values.flatMap { $0 }
                    .max(by: { $0.sessionCount < $1.sessionCount })
                    .map(Source.coworkAccount)
            }
            loadSessions()
        } catch {
            errorMessage = "\(error)"
        }
        isLoading = false
    }

    func loadSessions() {
        selectedRowIDs = []
        guard let source = selectedSource else { rows = []; return }
        do {
            switch source {
            case .coworkAccount(let account):
                rows = try Discovery.sessions(in: account)
                    .map(SessionRow.init)
                    .sorted { $0.date > $1.date }
            case .claudeCodeProject(let projectDir):
                rows = try Discovery.claudeCodeSessions(projectDir: projectDir, configDir: claudeCodeConfigDir)
                    .map(SessionRow.init)
                    .sorted { $0.date > $1.date }
            }
        } catch {
            errorMessage = "\(error)"
            rows = []
        }
    }

    /// Resolved once per refresh. The sidebar renders on every state change, and recovering a
    /// project's real path means reading a transcript, so doing it per-render made scrolling
    /// re-read hundreds of files.
    private var projectPaths: [URL: String] = [:]

    private func resolveProjectPaths() {
        projectPaths = [:]
        for projectDir in claudeCodeProjects {
            let sessions = (try? Discovery.claudeCodeSessions(projectDir: projectDir,
                                                              configDir: claudeCodeConfigDir)) ?? []
            if let cwd = sessions.first(where: { !$0.resolvedCwd.isEmpty })?.resolvedCwd {
                projectPaths[projectDir] = cwd
            }
        }
        // A project directory whose transcripts never recorded a cwd cannot be decoded — the
        // encoding maps `/`, `.`, `_` and space all to `-`, so it is not invertible. Drop
        // those rather than show an unreadable slug.
        claudeCodeProjects = claudeCodeProjects.filter { projectPaths[$0] != nil }
            .sorted { (projectPaths[$0] ?? "") < (projectPaths[$1] ?? "") }
    }

    // MARK: - Sidebar

    var desktopSources: [SidebarItem] {
        stores.flatMap { store -> [SidebarItem] in
            (accounts[store] ?? []).filter { $0.sessionCount > 0 }.map { account in
                SidebarItem(
                    source: .coworkAccount(account),
                    title: Self.shortIdentity(account),
                    symbol: isRunning(store) ? "circle.inset.filled" : "person",
                    badge: "\(account.sessionCount)",
                    badgeIsWide: false,
                    help: (account.emailAddress ?? account.accountId) + " — " + (isRunning(store)
                        ? "\(store.variantDirName), running, so it cannot receive a transfer until it is quit"
                        : store.variantDirName))
            }
        }
    }

    /// The local part of the address. Middle-truncating a full address destroys exactly the
    /// characters that distinguish one account from another, and the domain is almost always
    /// shared between them anyway.
    static func shortIdentity(_ account: AccountRef) -> String {
        guard let email = account.emailAddress else { return account.store.variantDirName }
        return String(email.split(separator: "@").first ?? Substring(email))
    }

    var projectSources: [SidebarItem] {
        claudeCodeProjects.map { dir in
            SidebarItem(source: .claudeCodeProject(dir), title: projectLabel(dir),
                        symbol: "folder", badge: projectParentLabel(dir), badgeIsWide: true,
                        help: projectPath(dir) ?? dir.lastPathComponent)
        }
    }

    /// The store name leads, because it is short and is what the user recognises; the
    /// address disambiguates underneath.
    var sourceTitle: String {
        switch selectedSource {
        case .coworkAccount(let account): return account.store.variantDirName
        case .claudeCodeProject(let dir): return projectLabel(dir)
        case nil: return "Better Claude"
        }
    }

    var sourceSubtitle: String {
        switch selectedSource {
        case .coworkAccount(let account):
            let identity = account.emailAddress ?? account.displayIdentity
            return isRunning(account.store) ? "\(identity) · running" : identity
        case .claudeCodeProject(let dir):
            return (projectPath(dir)?.abbreviatingHome) ?? dir.lastPathComponent
        case nil:
            return "Move conversations between Claude installs and Claude Code"
        }
    }

    /// Human-readable label for a Claude Code project directory.
    func projectLabel(_ projectDir: URL) -> String {
        guard let path = projectPaths[projectDir] else { return projectDir.lastPathComponent }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func projectPath(_ projectDir: URL) -> String? { projectPaths[projectDir] }

    /// The folder that actually identifies a project, shown beside auto-generated names like
    /// `wobbly-leaping-puppy` which are otherwise impossible to tell apart.
    ///
    /// Git worktrees live one level deeper than the thing a person thinks of as the project
    /// — `…/aquaview/.claude-worktrees/wobbly-leaping-puppy` — so a plain parent lookup
    /// returns the same machinery folder for every worktree on disk and identifies nothing.
    func projectParentLabel(_ projectDir: URL) -> String? {
        guard let path = projectPaths[projectDir] else { return nil }
        let home = NSString(string: NSHomeDirectory()).lastPathComponent
        var folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        while folder.lastPathComponent.hasPrefix(".") || folder.lastPathComponent.contains("worktree") {
            let next = folder.deletingLastPathComponent()
            if next.path == folder.path || next.path == "/" { break }
            folder = next
        }
        let name = folder.lastPathComponent
        guard name != home, name != "/", !name.isEmpty else { return nil }
        return name
    }
}
