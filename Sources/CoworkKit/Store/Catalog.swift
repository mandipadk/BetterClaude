import Foundation

/// One conversation, wherever it lives: a Cowork session, a Claude Code session, or a Code
/// tab session in a Desktop install.
public struct ConversationRef: Sendable, Hashable, Identifiable {
    public enum Origin: Sendable, Hashable {
        case cowork(SessionRef)
        case claudeCode(CCSessionRef)
        /// A Code tab record and, when it still exists, the transcript it points at.
        case codeTab(CodeTabSession, CCSessionRef?)
        /// A claude.ai or Codex conversation.
        case external(ExternalConversation)
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
    /// The Claude account the conversation belongs to, when that's known.
    public let accountID: String?

    public init(origin: Origin, installID: String, title: String, lastActivity: Date,
                projectPath: String?, model: String?, bytes: Int64, isStarred: Bool, isArchived: Bool,
                accountID: String? = nil) {
        self.origin = origin
        self.installID = installID
        self.title = title
        self.lastActivity = lastActivity
        self.projectPath = projectPath
        self.model = model
        self.bytes = bytes
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.accountID = accountID
    }

    public var id: String {
        switch origin {
        case .cowork(let session): return "cowork:" + session.metadataURL.path
        case .claudeCode(let session): return "cc:" + session.transcriptURL.path
        case .codeTab(let record, _): return "codetab:" + record.metadataURL.path
        case .external(let conversation): return "\(conversation.source.rawValue):" + conversation.id
        }
    }

    public var transcriptURL: URL? {
        switch origin {
        case .cowork(let session): return session.transcriptURL
        case .claudeCode(let session): return session.transcriptURL
        case .codeTab(_, let session): return session?.transcriptURL
        case .external: return nil
        }
    }

    /// The conversation's metadata survived but its messages did not — Claude Code's cleanup
    /// removed the transcript, or it was never written.
    public var isTranscriptMissing: Bool { transcriptURL == nil && external == nil }

    public var external: ExternalConversation? {
        if case .external(let conversation) = origin { return conversation }
        return nil
    }

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
        case .external(let conversation): return conversation.id
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
        case .cowork, .external: return nil
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
    /// The account Claude Code itself is signed into, if any.
    public var claudeCodeAccount: ClaudeAccount?

    public init(installs: [Install] = [], accounts: [String: [AccountRef]] = [:],
                conversations: [ConversationRef] = [], paths: HostPaths = .current) {
        self.installs = installs
        self.accounts = accounts
        self.conversations = conversations
        self.paths = paths
    }

    public func install(_ id: String) -> Install? { installs.first { $0.id == id } }

    /// Every account on the Mac that has conversations, with the best name for each.
    public var knownAccounts: [ClaudeAccount] {
        var byID: [String: ClaudeAccount] = [:]
        for refs in accounts.values {
            for ref in refs where byID[ref.accountId]?.email == nil {
                byID[ref.accountId] = ClaudeAccount(id: ref.accountId, email: ref.emailAddress)
            }
        }
        if let cli = claudeCodeAccount, byID[cli.id]?.email == nil { byID[cli.id] = cli }
        let used = Set(conversations.compactMap(\.accountID))
        if used.contains(ClaudeAccount.codex.id) { byID[ClaudeAccount.codex.id] = .codex }
        return byID.values.filter { used.contains($0.id) }.sorted { ($0.email ?? $0.id) < ($1.email ?? $1.id) }
    }

    /// The account an install is signed into: the Code tab's or Cowork's for a Desktop
    /// install, Claude Code's own for Claude Code.
    public func account(of install: Install) -> ClaudeAccount? {
        if install.kind == .claudeCode { return claudeCodeAccount }
        let refs = accounts[install.id] ?? []
        if let signedIn = refs.first(where: \.isSignedIn) ?? refs.max(by: { $0.sessionCount < $1.sessionCount }) {
            return ClaudeAccount(id: signedIn.accountId, email: signedIn.emailAddress)
        }
        let codeTab = conversations.first { $0.installID == install.id && $0.accountID != nil }
        return codeTab?.accountID.map { id in knownAccounts.first { $0.id == id } ?? ClaudeAccount(id: id, email: nil) }
    }

    public func conversations(in installID: String) -> [ConversationRef] {
        conversations.filter { $0.installID == installID }
    }
}

/// A Claude account, as far as this Mac knows it.
public struct ClaudeAccount: Sendable, Hashable, Identifiable {
    public let id: String
    public let email: String?
    /// A name for history that isn't a Claude account, like Codex's.
    public let label: String?

    public init(id: String, email: String?, label: String? = nil) {
        self.id = id
        self.email = email
        self.label = label
    }

    public var displayName: String { label ?? email ?? "Account \(id.prefix(8))" }

    /// Codex sessions, which a Claude can be let read like another account's history.
    public static let codex = ClaudeAccount(id: "codex", email: nil, label: "Codex sessions")

    /// The account Claude Code is signed into, from its state file.
    public static func claudeCode(paths: HostPaths = .current) -> ClaudeAccount? {
        let config = paths.claudeCodeConfigDir
        let state = config.standardizedFileURL == paths.home.appendingPathComponent(".claude").standardizedFileURL
            ? paths.home.appendingPathComponent(".claude.json")
            : config.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: state), let value = try? JSONValue.parse(data),
              let account = value["oauthAccount"], let id = account["accountUuid"]?.stringValue else { return nil }
        return ClaudeAccount(id: id, email: account["emailAddress"]?.stringValue)
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
                for session in (try? Discovery.sessions(in: account, measuringWorkspaces: false)) ?? [] {
                    conversations.append(ConversationRef(
                        origin: .cowork(session), installID: install.id,
                        title: session.title.isEmpty ? "Untitled conversation" : session.title,
                        lastActivity: session.lastActivityAt, projectPath: nil,
                        model: session.model.isEmpty ? nil : session.model,
                        bytes: session.byteSize, isStarred: false, isArchived: session.isArchived,
                        accountID: account.accountId))
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
                    isStarred: record.isStarred, isArchived: record.isArchived,
                    accountID: CodeTabSessions.accountID(of: record, root: root)))
            }
        }

        let cliAccount = ClaudeAccount.claudeCode(paths: paths)
        if let cli = installs.first(where: { $0.kind == .claudeCode }) {
            for session in claudeCode.values {
                conversations.append(ConversationRef(
                    origin: .claudeCode(session), installID: cli.id,
                    title: session.title, lastActivity: session.lastTimestamp,
                    projectPath: session.resolvedCwd.isEmpty ? nil : session.resolvedCwd,
                    model: nil, bytes: session.byteSize, isStarred: false, isArchived: false,
                    accountID: cliAccount?.id))
            }
        }

        // Conversations from outside Claude's apps, read-only.
        if let web = installs.first(where: { $0.kind == .external(.claudeWeb) }) {
            for (conversation, account) in ClaudeWebImport.conversations(paths: paths) {
                conversations.append(ConversationRef(
                    origin: .external(conversation), installID: web.id, title: conversation.title,
                    lastActivity: conversation.updatedAt, projectPath: nil, model: nil, bytes: 0,
                    isStarred: false, isArchived: false, accountID: account))
            }
        }
        if let codex = installs.first(where: { $0.kind == .external(.codex) }) {
            for conversation in CodexSessions.conversations(paths: paths) {
                conversations.append(ConversationRef(
                    origin: .external(conversation), installID: codex.id, title: conversation.title,
                    lastActivity: conversation.updatedAt, projectPath: conversation.cwd, model: conversation.model,
                    bytes: 0, isStarred: false, isArchived: false, accountID: ClaudeAccount.codex.id))
            }
        }

        for mac in installs where mac.kind == .external(.otherMac) {
            for conversation in OtherMacs.conversations(in: mac.dataRoot) {
                conversations.append(ConversationRef(
                    origin: .external(conversation), installID: mac.id, title: conversation.title,
                    lastActivity: conversation.updatedAt, projectPath: conversation.cwd, model: nil,
                    bytes: 0, isStarred: false, isArchived: false, accountID: nil))
            }
        }

        conversations.sort {
            $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
        }
        // A list with two rows of one id draws blank rows and selects the wrong one; keep the
        // newest of any that collide.
        var seen = Set<String>()
        conversations.removeAll { !seen.insert($0.id).inserted }
        var snapshot = CatalogSnapshot(installs: installs, accounts: accounts,
                                       conversations: conversations, paths: paths)
        snapshot.claudeCodeAccount = cliAccount
        return snapshot
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
