import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Where the main window is.
enum SidebarDestination: Hashable {
    case conversations
    case library
    case install(String)
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

    /// The transfer in progress, shown as a sheet.
    var transfer: TransferModel?

    func beginTransfer(_ conversation: ConversationRef) {
        let row: SessionRow
        if let session = conversation.coworkSession {
            row = SessionRow(session)
        } else if let session = conversation.claudeCodeSession {
            row = SessionRow(session)
        } else {
            return
        }
        // The transfer sheet still reads its destinations from the previous model.
        legacy.refresh()
        transfer = TransferModel(sessions: [row])
    }

    func endTransfer() {
        transfer = nil
        refresh()
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

extension TransferModel: Identifiable {}
