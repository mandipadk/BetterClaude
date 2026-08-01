import Foundation

/// A Claude Desktop data directory containing a Cowork session store.
///
/// Stores are discovered by scanning for `local-agent-mode-sessions/`, never by deriving a
/// path from an installed app. Variants are launched by passing Chromium's
/// `--user-data-dir` switch, and that value is an arbitrary string typed into a wrapper
/// script — `Claude Work.app` points at `Claude-Work` by human convention, not by any rule
/// the filesystem or bundle metadata encodes.
public struct StoreRef: Hashable, Sendable, Identifiable {
    /// Directory name under `~/Library/Application Support`, e.g. `Claude-Work`.
    public let variantDirName: String
    /// Canonicalized `--user-data-dir`.
    public let userDataDir: URL
    /// `userDataDir/local-agent-mode-sessions`.
    public let sessionsRoot: URL
    /// The app that launches this store, when one could be found. A store with no launcher
    /// is still fully readable and is surfaced rather than hidden.
    public let launcher: LauncherRef?

    public var id: String { userDataDir.path }
    public var isOrphan: Bool { launcher == nil }

    public init(variantDirName: String, userDataDir: URL, sessionsRoot: URL, launcher: LauncherRef?) {
        self.variantDirName = variantDirName
        self.userDataDir = userDataDir
        self.sessionsRoot = sessionsRoot
        self.launcher = launcher
    }
}

/// An installed application that can launch a Cowork store.
public struct LauncherRef: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// The real Electron app, `com.anthropic.claudefordesktop`.
        case electron
        /// An AppleScript applet wrapping `open -n -a Claude.app --args --user-data-dir=…`.
        case appleScriptWrapper
    }

    public let bundleURL: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let kind: Kind
    /// Parsed from the wrapper's `--user-data-dir`; `nil` means the Electron default.
    public let userDataDirOverride: URL?

    public init(bundleURL: URL, bundleIdentifier: String, displayName: String,
                kind: Kind, userDataDirOverride: URL?) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.kind = kind
        self.userDataDirOverride = userDataDirOverride
    }
}

/// How a store spells account and organization directory names.
///
/// Claude Desktop can address these directories either by full UUID or by the first eight
/// hex characters, lowercased, depending on a feature flag. Both forms must be accepted on
/// read, and whichever form the target already uses must be mirrored on write.
public enum DirScheme: String, Sendable {
    case fullUUID
    case shortHex8
}

/// One `<accountId>/<orgId>/` pair inside a store — the unit Claude Desktop actually lists
/// sessions from. Only the pair matching the signed-in account is ever read by the app.
public struct AccountRef: Hashable, Sendable, Identifiable {
    public let store: StoreRef
    public let accountId: String
    public let orgId: String
    public let dirScheme: DirScheme
    public let root: URL
    public let sessionCount: Int
    /// Read from any session in this account; `nil` when the account has no sessions yet.
    public let emailAddress: String?
    public let accountName: String?

    public var id: String { root.path }

    public init(store: StoreRef, accountId: String, orgId: String, dirScheme: DirScheme,
                root: URL, sessionCount: Int, emailAddress: String?, accountName: String?) {
        self.store = store
        self.accountId = accountId
        self.orgId = orgId
        self.dirScheme = dirScheme
        self.root = root
        self.sessionCount = sessionCount
        self.emailAddress = emailAddress
        self.accountName = accountName
    }

    public var displayIdentity: String {
        if let emailAddress { return emailAddress }
        return "\(accountId.prefix(8))…/\(orgId.prefix(8))…"
    }
}

/// A single Cowork session: a `local_<uuid>.json` plus its sibling `local_<uuid>/` workspace.
public struct SessionRef: Hashable, Sendable, Identifiable {
    public let account: AccountRef
    /// `local_<uuid>` — also the metadata filename stem and the workspace directory name.
    public let sessionId: String
    /// The transcript's UUID; names `<cliSessionId>.jsonl`. Distinct from `sessionId`.
    public let cliSessionId: String
    public let title: String
    public let model: String
    public let createdAt: Date
    public let lastActivityAt: Date
    /// `true` when `cwd` is a real host path rather than an in-VM `/sessions/<name>` path.
    public let hostLoopMode: Bool?
    public let processName: String
    public let cwd: String
    public let isArchived: Bool

    public let metadataURL: URL
    public let workspaceURL: URL
    /// `nil` when the transcript could not be located — surfaced as a warning, not an error.
    public let projectDirURL: URL?
    public let transcriptURL: URL?
    /// Other `.jsonl` files beside the real transcript. Never auto-imported.
    public let straySiblingTranscripts: [URL]
    public let byteSize: Int64

    public var id: String { metadataURL.path }

    public init(account: AccountRef, sessionId: String, cliSessionId: String, title: String,
                model: String, createdAt: Date, lastActivityAt: Date, hostLoopMode: Bool?,
                processName: String, cwd: String, isArchived: Bool, metadataURL: URL,
                workspaceURL: URL, projectDirURL: URL?, transcriptURL: URL?,
                straySiblingTranscripts: [URL], byteSize: Int64) {
        self.account = account
        self.sessionId = sessionId
        self.cliSessionId = cliSessionId
        self.title = title
        self.model = model
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.hostLoopMode = hostLoopMode
        self.processName = processName
        self.cwd = cwd
        self.isArchived = isArchived
        self.metadataURL = metadataURL
        self.workspaceURL = workspaceURL
        self.projectDirURL = projectDirURL
        self.transcriptURL = transcriptURL
        self.straySiblingTranscripts = straySiblingTranscripts
        self.byteSize = byteSize
    }
}

/// A native Claude Code session: one `.jsonl` under `<configDir>/projects/<encoded-cwd>/`.
public struct CCSessionRef: Hashable, Sendable, Identifiable {
    public let configDir: URL
    public let projectDir: URL
    /// The working directory this project directory encodes, recovered from the transcript
    /// (the directory name itself is a lossy encoding and cannot be inverted).
    public let resolvedCwd: String
    public let sessionId: String
    public let transcriptURL: URL
    public let title: String
    public let recordCount: Int
    public let firstTimestamp: Date
    public let lastTimestamp: Date
    public let byteSize: Int64

    public var id: String { transcriptURL.path }

    public init(configDir: URL, projectDir: URL, resolvedCwd: String, sessionId: String,
                transcriptURL: URL, title: String, recordCount: Int, firstTimestamp: Date,
                lastTimestamp: Date, byteSize: Int64) {
        self.configDir = configDir
        self.projectDir = projectDir
        self.resolvedCwd = resolvedCwd
        self.sessionId = sessionId
        self.transcriptURL = transcriptURL
        self.title = title
        self.recordCount = recordCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.byteSize = byteSize
    }
}

/// Where a transfer is going.
public enum Endpoint: Sendable, Hashable {
    case cowork(AccountRef)
    case claudeCode(projectDir: URL, configDir: URL)

    public var describedDestination: String {
        switch self {
        case .cowork(let a): return "\(a.store.variantDirName) · \(a.displayIdentity)"
        case .claudeCode(let p, _): return "Claude Code · \(p.path)"
        }
    }
}

/// Shared regular expressions and constants describing the on-disk layout.
public enum StoreLayout {
    public static let sessionsDirName = "local-agent-mode-sessions"
    public static let sessionPrefix = "local_"
    /// Sessions live in `<org>/` and also in `<org>/agent/`; both must be scanned.
    public static let agentSubdirName = "agent"

    public static func isFullUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        return s.wholeMatch(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) != nil
    }

    public static func isShortHex8(_ s: String) -> Bool {
        s.count == 8 && s.wholeMatch(of: /[0-9a-f]{8}/) != nil
    }

    /// Level-1 entries under `local-agent-mode-sessions/` must look like an account id.
    ///
    /// `skills-plugin/` sits at exactly this level and inverts the order of its children to
    /// `<orgId>/<accountId>/`, so a scanner that accepts any directory name here will
    /// produce accounts and orgs that are swapped.
    public static func isAccountDirName(_ s: String) -> Bool {
        isFullUUID(s) || isShortHex8(s)
    }

    /// Claude Code only lists transcripts whose filename stem is a UUID and whose extension
    /// is exactly `.jsonl`.
    public static func isTranscriptFileName(_ s: String) -> Bool {
        guard s.hasSuffix(".jsonl") else { return false }
        return isFullUUID(String(s.dropLast(6)))
    }
}
