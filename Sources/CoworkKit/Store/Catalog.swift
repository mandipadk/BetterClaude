import Foundation

/// One conversation, wherever it lives: a Cowork session, a Claude Code session, or a Code
/// tab session in a Desktop install.
public struct ConversationRef: Sendable, Hashable, Identifiable {
    public enum Origin: Sendable, Hashable {
        case cowork(SessionRef)
        case claudeCode(CCSessionRef)
        /// A Code tab record and, when it still exists, the transcript it points at.
        case codeTab(CodeTabSession, CCSessionRef?)
    }

    public let origin: Origin
    public let installID: String
    public let title: String
    public let lastActivity: Date
    /// The folder a Claude Code conversation worked in; `nil` for Cowork.
    public let projectPath: String?
    public let model: String?
    public let bytes: Int64
    public let isStarred: Bool
    public let isArchived: Bool

    public var id: String {
        switch origin {
        case .cowork(let session): return "cowork:" + session.metadataURL.path
        case .claudeCode(let session): return "cc:" + session.transcriptURL.path
        case .codeTab(let record, _): return "codetab:" + record.metadataURL.path
        }
    }

    public var transcriptURL: URL? {
        switch origin {
        case .cowork(let session): return session.transcriptURL
        case .claudeCode(let session): return session.transcriptURL
        case .codeTab(_, let session): return session?.transcriptURL
        }
    }

    /// The conversation's metadata survived but its messages did not — Claude Code's cleanup
    /// removed the transcript, or it was never written.
    public var isTranscriptMissing: Bool { transcriptURL == nil }

    /// The folder's own name, which is what a person calls a project.
    public var projectName: String? {
        projectPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The transcript's Claude Code session id, the one `claude --resume` takes.
    public var cliSessionId: String {
        switch origin {
        case .cowork(let session): return session.cliSessionId
        case .claudeCode(let session): return session.sessionId
        case .codeTab(let record, _): return record.cliSessionId
        }
    }

    public var coworkSession: SessionRef? {
        if case .cowork(let session) = origin { return session }
        return nil
    }

    public var claudeCodeSession: CCSessionRef? {
        switch origin {
        case .claudeCode(let session): return session
        case .codeTab(_, let session): return session
        case .cowork: return nil
        }
    }
}

/// Everything on this Mac at one moment: its installs, their accounts, and every
/// conversation across all of them, most recent first.
public struct CatalogSnapshot: Sendable {
    public var installs: [Install]
    /// Accounts in each install's Cowork store, keyed by install id.
    public var accounts: [String: [AccountRef]]
    public var conversations: [ConversationRef]
    public var paths: HostPaths

    public init(installs: [Install] = [], accounts: [String: [AccountRef]] = [:],
                conversations: [ConversationRef] = [], paths: HostPaths = .current) {
        self.installs = installs
        self.accounts = accounts
        self.conversations = conversations
        self.paths = paths
    }

    public func install(_ id: String) -> Install? { installs.first { $0.id == id } }

    public func conversations(in installID: String) -> [ConversationRef] {
        conversations.filter { $0.installID == installID }
    }
}

/// The one place that walks the disk for conversations.
///
/// Listing a Claude Code transcript means reading both ends of it; with hundreds of
/// transcripts that adds up, so each summary is kept and reused until the file's size or
/// modification date changes. A refresh after a transfer therefore costs one read per file
/// that actually changed.
public actor Catalog {

    struct CachedSummary {
        let size: Int64
        let modified: Date
        let session: CCSessionRef
    }

    private var summaries: [String: CachedSummary] = [:]
    private let paths: HostPaths

    public init(paths: HostPaths = .current) {
        self.paths = paths
    }

    public func snapshot() async -> CatalogSnapshot {
        let paths = self.paths
        return await HostPaths.$current.withValue(paths) {
            await build()
        }
    }

    private func build() async -> CatalogSnapshot {
        let installs = InstallDiscovery.all()
        let stores = installs.compactMap(\.store)
        let orgDirectory = OrgDirectory.build(stores: stores)

        var accounts: [String: [AccountRef]] = [:]
        var conversations: [ConversationRef] = []

        for install in installs {
            guard let store = install.store else { continue }
            let found = (try? Discovery.accounts(in: store, orgDirectory: orgDirectory)) ?? []
            accounts[install.id] = found
            for account in found where account.sessionCount > 0 {
                for session in (try? Discovery.sessions(in: account)) ?? [] {
                    conversations.append(ConversationRef(
                        origin: .cowork(session), installID: install.id,
                        title: session.title.isEmpty ? "Untitled conversation" : session.title,
                        lastActivity: session.lastActivityAt, projectPath: nil,
                        model: session.model.isEmpty ? nil : session.model,
                        bytes: session.byteSize, isStarred: false, isArchived: session.isArchived))
                }
            }
        }

        // Claude Code transcripts, keyed by session id so Code tab records can claim theirs.
        var claudeCode: [String: CCSessionRef] = [:]
        let config = paths.claudeCodeConfigDir
        for project in (try? Discovery.claudeCodeProjects(configDir: config)) ?? [] {
            for session in sessions(inProject: project, configDir: config) {
                claudeCode[session.sessionId] = session
            }
        }

        for install in installs {
            guard let root = install.codeTabRoot else { continue }
            for record in CodeTabSessions.sessions(in: root) {
                let transcript = claudeCode.removeValue(forKey: record.cliSessionId)
                conversations.append(ConversationRef(
                    origin: .codeTab(record, transcript), installID: install.id,
                    title: record.title.isEmpty ? (transcript?.title ?? "Untitled session") : record.title,
                    lastActivity: record.lastActivityAt ?? transcript?.lastTimestamp
                        ?? record.createdAt ?? Date(timeIntervalSince1970: 0),
                    projectPath: record.cwd.isEmpty ? transcript?.resolvedCwd : record.cwd,
                    model: record.model, bytes: transcript?.byteSize ?? 0,
                    isStarred: record.isStarred, isArchived: record.isArchived))
            }
        }

        if let cli = installs.first(where: { $0.kind == .claudeCode }) {
            for session in claudeCode.values {
                conversations.append(ConversationRef(
                    origin: .claudeCode(session), installID: cli.id,
                    title: session.title, lastActivity: session.lastTimestamp,
                    projectPath: session.resolvedCwd.isEmpty ? nil : session.resolvedCwd,
                    model: nil, bytes: session.byteSize, isStarred: false, isArchived: false))
            }
        }

        conversations.sort {
            $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
        }
        return CatalogSnapshot(installs: installs, accounts: accounts,
                               conversations: conversations, paths: paths)
    }

    /// One project's transcripts, reusing every summary whose file has not changed.
    private func sessions(inProject project: URL, configDir: URL) -> [CCSessionRef] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var result: [CCSessionRef] = []
        var stale = false
        for url in entries where StoreLayout.isTranscriptFileName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            if let cached = summaries[url.path], cached.size == size, cached.modified == modified {
                result.append(cached.session)
            } else {
                stale = true
                break
            }
        }
        guard stale || result.isEmpty else { return result }

        let fresh = (try? Discovery.claudeCodeSessions(projectDir: project, configDir: configDir,
                                                       countingRecords: false)) ?? []
        for session in fresh {
            let values = try? session.transcriptURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            summaries[session.transcriptURL.path] = CachedSummary(
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                session: session)
        }
        return fresh
    }
}
