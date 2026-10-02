import Foundation

public enum DiscoveryError: Error, CustomStringConvertible {
    case unreadableDirectory(URL, reason: String)

    public var description: String {
        switch self {
        case .unreadableDirectory(let url, let reason):
            return "cannot list \(url.path): \(reason)"
        }
    }
}

/// Read-only enumeration of Cowork stores and Claude Code transcripts on this machine.
///
/// Nothing here writes, creates, or moves a file. Both applications discover sessions by
/// walking directories — there is no index, no database, and no daemon to ask — so this is
/// a faithful reimplementation of a directory scan, with the same tolerance the apps have
/// for junk: an unreadable directory, a dangling symlink, or a half-written JSON file
/// removes one entry from the results and never aborts the walk.
public enum Discovery {

    // MARK: - Stores

    /// Every `~/Library/Application Support/<Variant>/` that contains a session store.
    ///
    /// The filesystem is the only authority. Deriving store paths from installed apps would
    /// both miss stores whose launcher was deleted and invent stores for launchers pointing
    /// at directories Claude Desktop has never actually created.
    public static func stores() throws -> [StoreRef] {
        let root = applicationSupportDirectory()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            throw DiscoveryError.unreadableDirectory(root, reason: "\(error)")
        }

        let index = launcherIndex()
        var result: [StoreRef] = []
        for entry in entries where isDirectory(entry) {
            let sessionsRoot = entry.appendingPathComponent(
                StoreLayout.sessionsDirName, isDirectory: true)
            guard isDirectory(sessionsRoot) else { continue }
            let canonical = canonical(entry)
            result.append(StoreRef(
                variantDirName: entry.lastPathComponent,
                userDataDir: canonical,
                sessionsRoot: sessionsRoot,
                launcher: index[canonical.path]))
        }
        // Parallex keeps its copies' data inside its own folder rather than beside Claude's,
        // so they are one level deeper than the scan above looks.
        result += InstallDiscovery.parallexStores()
        return result.sorted { $0.variantDirName < $1.variantDirName }
    }

    // MARK: - Launchers

    /// Applications that can open a Cowork store, from `/Applications` and `~/Applications`.
    ///
    /// Two shapes exist. The real Electron app is `com.anthropic.claudefordesktop` and uses
    /// the default `Claude` data directory. Every variant is a Script Editor applet that
    /// shells out to the same binary with `--user-data-dir=…`; its bundle identifier is
    /// whatever Script Editor generated and carries no information, so the switch inside the
    /// compiled script is the only place the variant name exists.
    public static func launchers() throws -> [LauncherRef] {
        var result: [LauncherRef] = []
        var seen = Set<String>()
        for directory in applicationDirectories() {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            for bundle in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where bundle.pathExtension == "app" {
                guard let launcher = launcher(atBundle: bundle) else { continue }
                guard seen.insert(launcher.bundleURL.path).inserted else { continue }
                result.append(launcher)
            }
        }
        return result
    }

    /// `com.anthropic.operon` is Claude Science: a native app that shares the family name
    /// and keeps no Cowork store, so treating it as a launcher would produce a variant that
    /// can never have sessions.
    public static let excludedBundleIdentifiers: Set<String> = ["com.anthropic.operon"]

    public static let electronBundleIdentifier = "com.anthropic.claudefordesktop"

    // MARK: - Accounts

    /// The account id an install is currently signed into, or `nil`.
    ///
    /// `config.json` records this as `lastKnownAccountUuid`, independently of whether any
    /// conversation has been started. That is the honest signal for "Claude Desktop will read
    /// what I write here"; session count is not, because a freshly signed-in install has no
    /// sessions and is still a valid destination.
    ///
    /// Exactly one key is read. The same file holds `oauth:tokenCache`, which is a credential
    /// and is never read, logged, or carried into a bundle.
    public static func signedInAccountId(in store: StoreRef) -> String? {
        let configURL = store.userDataDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object["lastKnownAccountUuid"] as? String,
              !uuid.isEmpty
        else { return nil }
        return uuid
    }

    /// The `<accountId>/<orgId>` pairs inside a store, including pairs with no sessions yet.
    /// `orgDirectory` is passed in when several stores are enumerated together, so the scan
    /// for organisation names happens once for the machine rather than once per store.
    public static func accounts(in store: StoreRef,
                                orgDirectory: OrgDirectory.Resolved? = nil) throws -> [AccountRef] {
        let level1 = (try? FileManager.default.contentsOfDirectory(
            at: store.sessionsRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        let signedIn = signedInAccountId(in: store)
        let directory = orgDirectory ?? OrgDirectory.build(stores: [store])
        var result: [AccountRef] = []
        for accountDir in level1.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let accountId = accountDir.lastPathComponent
            // `skills-plugin/` lives at exactly this level and stores its children in the
            // opposite order, so accepting any directory name here silently swaps every
            // account id with an org id.
            guard StoreLayout.isAccountDirName(accountId), isDirectory(accountDir) else { continue }
            let scheme: DirScheme = StoreLayout.isFullUUID(accountId) ? .fullUUID : .shortHex8

            let level2 = (try? FileManager.default.contentsOfDirectory(
                at: accountDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for orgDir in level2.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let orgId = orgDir.lastPathComponent
                guard StoreLayout.isAccountDirName(orgId), isDirectory(orgDir) else { continue }

                let metadataFiles = sessionMetadataURLs(inOrg: orgDir)
                let identity = accountIdentity(fromCheapestOf: metadataFiles)
                result.append(AccountRef(
                    store: store,
                    accountId: accountId,
                    orgId: orgId,
                    dirScheme: scheme,
                    root: orgDir,
                    sessionCount: metadataFiles.count,
                    emailAddress: identity.emailAddress,
                    accountName: identity.accountName,
                    isSignedIn: signedIn == accountId,
                    org: directory.orgs[orgId],
                    orgAccountCount: directory.accountsPerOrg[orgId] ?? 1))
            }
        }
        return propagatingIdentityAcrossOrgs(result).map { account in
            // An install signed into but never used has no session to read an address from,
            // yet Claude Code's own record names it. Better than a bare UUID.
            guard account.emailAddress == nil,
                  let email = directory.accountEmails[account.accountId] else { return account }
            return AccountRef(store: account.store, accountId: account.accountId,
                              orgId: account.orgId, dirScheme: account.dirScheme,
                              root: account.root, sessionCount: account.sessionCount,
                              emailAddress: email, accountName: account.accountName,
                              isSignedIn: account.isSignedIn, org: account.org,
                              orgAccountCount: account.orgAccountCount)
        }
    }

    /// Give an account's empty orgs the identity read from its populated ones.
    ///
    /// `emailAddress` comes out of session metadata, so an org with no sessions has none —
    /// even when a sibling org of the *same account* names the person plainly. Left alone,
    /// one account renders under two different names: "iris@…" for the org that has
    /// conversations and the bare install name for the org that does not, which reads as two
    /// unrelated accounts rather than one.
    static func propagatingIdentityAcrossOrgs(_ accounts: [AccountRef]) -> [AccountRef] {
        var identity: [String: (email: String?, name: String?)] = [:]
        for account in accounts where account.emailAddress != nil {
            if identity[account.accountId] == nil {
                identity[account.accountId] = (account.emailAddress, account.accountName)
            }
        }
        guard !identity.isEmpty else { return accounts }
        return accounts.map { account in
            guard account.emailAddress == nil,
                  let known = identity[account.accountId] else { return account }
            return AccountRef(store: account.store, accountId: account.accountId,
                              orgId: account.orgId, dirScheme: account.dirScheme,
                              root: account.root, sessionCount: account.sessionCount,
                              emailAddress: known.email, accountName: known.name,
                              // Carried through explicitly. Dropping it here silently
                              // un-resolved the org of every account whose address was
                              // inherited — the same org id showed a name under one install
                              // and a bare UUID under another.
                              isSignedIn: account.isSignedIn, org: account.org,
                              orgAccountCount: account.orgAccountCount)
        }
    }

    // MARK: - Sessions

    /// Sessions in an account, most recently active first.
    ///
    /// A session whose metadata will not parse is dropped rather than thrown, because a
    /// single half-written file — Claude Desktop writes these while it runs — must not make
    /// the other fifty invisible.
    ///
    /// `measuringWorkspaces: false` sizes a session by its metadata and transcript rather than
    /// walking its whole workspace — which can hold thousands of files and would make a
    /// listing that refreshes while Claude is writing expensive.
    public static func sessions(in account: AccountRef,
                                measuringWorkspaces: Bool = true) throws -> [SessionRef] {
        var result: [SessionRef] = []
        for metadataURL in sessionMetadataURLs(inOrg: account.root) {
            guard let document = try? MetadataDocument(contentsOf: metadataURL) else { continue }
            guard let session = makeSession(account: account, metadataURL: metadataURL,
                                            document: document,
                                            measuringWorkspace: measuringWorkspaces) else { continue }
            result.append(session)
        }
        return result.sorted {
            $0.lastActivityAt == $1.lastActivityAt
                ? $0.sessionId < $1.sessionId
                : $0.lastActivityAt > $1.lastActivityAt
        }
    }

    // MARK: - Claude Code

    /// `$CLAUDE_CONFIG_DIR` if set, otherwise `~/.claude`.
    public static func defaultClaudeCodeConfigDir() -> URL {
        HostPaths.current.claudeCodeConfigDir
    }

    /// Project directories under `<configDir>/projects/`.
    ///
    /// Returns an empty list rather than throwing when `projects/` is absent: that is a
    /// Claude Code installation that has not run yet, not an error.
    public static func claudeCodeProjects(configDir: URL) throws -> [URL] {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        guard isDirectory(projects) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw DiscoveryError.unreadableDirectory(projects, reason: "\(error)")
        }
        return entries.filter { isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Transcripts in one project directory.
    ///
    /// Titles and timestamps are recovered from the first and last 64 KiB only. These files
    /// routinely pass 20 MB, and the title records the CLI appends (`custom-title`,
    /// `ai-title`, `last-prompt`) land at the end while the opening prompt and `cwd` land at
    /// the start, so both windows are needed and nothing in between is.
    ///
    /// `countingRecords: false` skips the one step that reads the whole file. A listing that
    /// never shows the count should not pay a sequential read of every transcript for it.
    public static func claudeCodeSessions(projectDir: URL, configDir: URL,
                                          countingRecords: Bool = true) throws -> [CCSessionRef] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let timestamps = TimestampParser()

        var result: [CCSessionRef] = []
        // Only plain files: opening a pipe or socket named like a transcript would wait forever.
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where StoreLayout.isTranscriptFileName(url.lastPathComponent)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            guard let summary = summarizeTranscript(at: url, timestamps: timestamps,
                                                    countingRecords: countingRecords) else { continue }
            result.append(CCSessionRef(
                configDir: configDir,
                projectDir: projectDir,
                resolvedCwd: summary.cwd ?? "",
                sessionId: String(url.lastPathComponent.dropLast(6)),
                transcriptURL: url,
                title: summary.title,
                recordCount: summary.recordCount,
                firstTimestamp: summary.firstTimestamp,
                lastTimestamp: summary.lastTimestamp,
                byteSize: summary.byteSize))
        }
        return result.sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}

// MARK: - Store and launcher internals

extension Discovery {

    static func homeDirectory() -> URL {
        HostPaths.current.home
    }

    static func applicationSupportDirectory() -> URL {
        HostPaths.current.applicationSupport
    }

    static func applicationDirectories() -> [URL] {
        HostPaths.current.applicationDirectories
    }

    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// `isDirectory` resolves symlinks, so a dangling link answers `false` instead of
    /// throwing further up the walk.
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// Maps a canonical user-data directory onto the app that opens it.
    static func launcherIndex() -> [String: LauncherRef] {
        let defaultUserDataDir = canonical(
            applicationSupportDirectory().appendingPathComponent("Claude", isDirectory: true))
        var index: [String: LauncherRef] = [:]
        for launcher in (try? launchers()) ?? [] {
            let target = launcher.userDataDirOverride.map(canonical) ?? defaultUserDataDir
            if index[target.path] == nil { index[target.path] = launcher }
        }
        return index
    }

    static func launcher(atBundle bundleURL: URL) -> LauncherRef? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let info = object as? [String: Any]
        else { return nil }

        let bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        guard !excludedBundleIdentifiers.contains(bundleIdentifier) else { return nil }

        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        if bundleIdentifier == electronBundleIdentifier {
            return LauncherRef(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier,
                               displayName: displayName, kind: .electron, userDataDirOverride: nil)
        }

        guard info["CFBundleExecutable"] as? String == "applet",
              let override = appletUserDataDir(inBundle: bundleURL)
        else { return nil }

        return LauncherRef(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier,
                           displayName: displayName, kind: .appleScriptWrapper,
                           userDataDirOverride: override)
    }

    /// Recover `--user-data-dir` from a compiled AppleScript applet.
    ///
    /// `main.scpt` is a tokenized binary: the switch is not present as text, so `strings`
    /// and `grep` both find nothing. Only the OSA API can render the source back, and only
    /// `source` is touched here — `executeAndReturnError` would launch the app.
    ///
    /// The rendered source is AppleScript, not shell, so the quotes around the value arrive
    /// backslash-escaped (`--user-data-dir=\"$HOME/…\"`) and both spellings are accepted.
    static func appletUserDataDir(inBundle bundleURL: URL) -> URL? {
        let scriptURL = bundleURL.appendingPathComponent("Contents/Resources/Scripts/main.scpt")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return nil }
        var scriptError: NSDictionary?
        guard let source = NSAppleScript(contentsOf: scriptURL, error: &scriptError)?.source,
              let raw = userDataDirArgument(inShellText: source)
        else { return nil }

        let expanded = expandHome(raw)
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    static func userDataDirArgument(inShellText text: String) -> String? {
        guard let marker = text.range(of: "--user-data-dir=") else { return nil }
        var index = marker.upperBound
        var quoted = false
        if text[index...].hasPrefix("\\\"") {
            quoted = true
            index = text.index(index, offsetBy: 2)
        } else if text[index...].hasPrefix("\"") {
            quoted = true
            index = text.index(after: index)
        }

        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" || character == "\\" { break }
            if !quoted, character == " " { break }
            value.append(character)
            index = text.index(after: index)
        }
        return value.isEmpty ? nil : value
    }

    static func expandHome(_ path: String) -> String {
        let home = HostPaths.current.home.path
        for token in ["${HOME}", "$HOME"] where path.hasPrefix(token) {
            return home + String(path.dropFirst(token.count))
        }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return path
    }
}

// MARK: - Session internals

extension Discovery {

    /// Metadata files directly under an org directory and under its `agent/` subdirectory.
    static func sessionMetadataURLs(inOrg orgDir: URL) -> [URL] {
        var result: [URL] = []
        for directory in [orgDir, orgDir.appendingPathComponent(
            StoreLayout.agentSubdirName, isDirectory: true)] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            for entry in entries where isSessionMetadataName(entry.lastPathComponent) {
                result.append(entry)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isSessionMetadataName(_ name: String) -> Bool {
        guard name.hasPrefix(StoreLayout.sessionPrefix), name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5).dropFirst(StoreLayout.sessionPrefix.count)
        return StoreLayout.isFullUUID(String(stem))
    }

    /// Read the identity fields from the smallest session file in the org.
    ///
    /// Every session in an account carries the same `emailAddress` and `accountName`, so
    /// one parse is enough — and the smallest file is the cheapest one to parse.
    static func accountIdentity(fromCheapestOf urls: [URL]) -> (emailAddress: String?, accountName: String?) {
        guard let smallest = urls.min(by: { fileSize($0) < fileSize($1) }),
              let document = try? MetadataDocument(contentsOf: smallest)
        else { return (nil, nil) }
        return (document.emailAddress, document.accountName)
    }

    static func makeSession(account: AccountRef, metadataURL: URL,
                            document: MetadataDocument, measuringWorkspace: Bool = true) -> SessionRef? {
        let filenameStem = String(metadataURL.lastPathComponent.dropLast(5))
        let sessionId = document.sessionId ?? filenameStem
        // Without the transcript's own id there is nothing to look up and nothing to
        // transfer, so this is the one field whose absence disqualifies a session.
        guard let cliSessionId = document.cliSessionId, !cliSessionId.isEmpty else { return nil }

        let cwd = document.cwd ?? ""
        let workspaceURL = workspaceDirectory(org: metadataURL.deletingLastPathComponent(),
                                              sessionId: sessionId, cwd: cwd)
        let located = locateTranscript(workspace: workspaceURL, cwd: cwd, cliSessionId: cliSessionId)

        return SessionRef(
            account: account,
            sessionId: sessionId,
            cliSessionId: cliSessionId,
            title: document.title ?? "",
            model: document.model ?? "",
            createdAt: document.createdAt ?? Date(timeIntervalSince1970: 0),
            lastActivityAt: document.lastActivityAt ?? document.createdAt
                ?? Date(timeIntervalSince1970: 0),
            hostLoopMode: document.hostLoopMode,
            processName: document.processName ?? "",
            cwd: cwd,
            isArchived: document.isArchived,
            metadataURL: metadataURL,
            workspaceURL: workspaceURL,
            projectDirURL: located.projectDir,
            transcriptURL: located.transcript,
            straySiblingTranscripts: located.strays,
            byteSize: fileSize(metadataURL) + (measuringWorkspace
                ? directorySize(workspaceURL)
                : located.transcript.map(fileSize) ?? 0))
    }

    /// A session's workspace folder. Claude Desktop named it `<sessionId>` until September 2026
    /// and now uses the first eight characters of the session's uuid; a host-loop session's
    /// `cwd` points into it too.
    static func workspaceDirectory(org: URL, sessionId: String, cwd: String) -> URL {
        let full = org.appendingPathComponent(sessionId, isDirectory: true)
        if isDirectory(full) { return full }
        let uuid = sessionId.hasPrefix(StoreLayout.sessionPrefix)
            ? String(sessionId.dropFirst(StoreLayout.sessionPrefix.count)) : sessionId
        let short = org.appendingPathComponent(String(uuid.prefix(8)), isDirectory: true)
        if uuid.count > 8, isDirectory(short) { return short }
        // `<org>/<folder>/outputs`, written by the app for sessions that work on the host.
        let orgPath = org.standardizedFileURL.path + "/"
        var folder = URL(fileURLWithPath: cwd)
        if folder.lastPathComponent == "outputs" { folder.deleteLastPathComponent() }
        if !cwd.isEmpty, folder.standardizedFileURL.path.hasPrefix(orgPath),
           folder.deletingLastPathComponent().standardizedFileURL.path + "/" == orgPath,
           isDirectory(folder) {
            return folder
        }
        return full
    }

    /// Find `<cliSessionId>.jsonl` beneath a workspace's `.claude/projects/`.
    ///
    /// The encoded name is tried first, including the sibling candidates that share a
    /// truncated prefix. When that misses, every project directory is scanned by filename —
    /// which is what Claude Desktop itself falls back to, and is why sessions whose `cwd`
    /// was rewritten after the transcript was created still open.
    static func locateTranscript(workspace: URL, cwd: String, cliSessionId: String)
        -> (projectDir: URL?, transcript: URL?, strays: [URL]) {
        let projects = workspace
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard isDirectory(projects) else { return (nil, nil, []) }

        let transcriptName = "\(cliSessionId).jsonl"
        var searchOrder: [URL] = []
        if !cwd.isEmpty {
            searchOrder = (try? PathEncoder.candidateDirectories(for: cwd, in: projects)) ?? []
        }
        let all = ((try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for candidate in all where !searchOrder.contains(candidate) {
            searchOrder.append(candidate)
        }

        for directory in searchOrder {
            let transcript = directory.appendingPathComponent(transcriptName)
            guard FileManager.default.fileExists(atPath: transcript.path) else { continue }
            let siblings = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != transcriptName }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return (directory, transcript, siblings)
        }
        return (nil, nil, [])
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            guard let values = try? entry.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Transcript summarization

extension Discovery {

    struct TranscriptSummary {
        var title: String
        var cwd: String?
        var recordCount: Int
        var firstTimestamp: Date
        var lastTimestamp: Date
        var byteSize: Int64
    }

    /// How much of each end of a transcript is parsed. 64 KiB comfortably covers the opening
    /// records at the head and the appended title records at the tail.
    static let transcriptWindow = 64 * 1024

    static let untitledTranscript = TitleResolver.placeholder

    /// The subset of a transcript this package needs in order to list it, besides its title.
    struct TranscriptFields {
        var cwd: String?
        var firstTimestamp: Date?
        /// The last thing someone said, which is when the conversation was last active.
        var lastMessageTimestamp: Date?
        /// Any record's, for a transcript in which nobody said anything.
        var lastTimestamp: Date?
    }

    static let parentMarker = Data("\"parentUuid\"".utf8)

    /// Whether `marker` appears anywhere in the file, read in chunks. Both ends of a long
    /// session can be nothing but bookkeeping while the middle holds the conversation.
    static func contains(_ marker: Data, in handle: FileHandle) -> Bool {
        guard (try? handle.seek(toOffset: 0)) != nil else { return false }
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let window = carry + chunk
            if window.range(of: marker) != nil { return true }
            carry = window.suffix(marker.count - 1)
        }
        return false
    }

    static func summarizeTranscript(at url: URL, timestamps: TimestampParser,
                                    countingRecords: Bool = true) -> TranscriptSummary? {
        let size = fileSize(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var head = Data()
        var tail = Data()
        let wholeFileFits = size <= Int64(2 * transcriptWindow)
        if wholeFileFits {
            head = (try? handle.readToEnd()) ?? Data()
        } else {
            head = (try? handle.read(upToCount: transcriptWindow)) ?? Data()
            if (try? handle.seek(toOffset: UInt64(size - Int64(transcriptWindow)))) != nil {
                tail = (try? handle.readToEnd()) ?? Data()
            }
        }
        // Claude Code lists only transcripts with a conversation in them; a file of nothing
        // but bookkeeping, such as a lone bridge-session record, isn't one.
        guard head.range(of: parentMarker) != nil || tail.range(of: parentMarker) != nil
              || (!wholeFileFits && contains(parentMarker, in: handle)) else { return nil }

        // A window cut mid-record leaves a fragment at the head's end and the tail's start.
        var headLines = splitLines(head)
        if !wholeFileFits, !headLines.isEmpty { headLines.removeLast() }
        var tailLines = splitLines(tail)
        if !tailLines.isEmpty { tailLines.removeFirst() }

        let tailFields = scanTail(tailLines, timestamps: timestamps)
        let headFields = scanHead(headLines, timestamps: timestamps)
        let title = TitleResolver.resolve(headLines: headLines, tailLines: tailLines,
                                          sidecarTitle: TitleResolver.sidecarTitle(forTranscript: url))?.title

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        let firstTimestamp = headFields.firstTimestamp ?? tailFields.firstTimestamp ?? modified
        // A record written after the last message — a title, a hook's summary — doesn't make
        // the conversation more recent, and nothing in it happened after the file last changed.
        let lastActive = tailFields.lastMessageTimestamp ?? headFields.lastMessageTimestamp
            ?? tailFields.lastTimestamp ?? headFields.lastTimestamp ?? firstTimestamp
        let lastTimestamp = max(firstTimestamp, min(lastActive, modified))

        var cwd = headFields.cwd ?? tailFields.cwd
        if cwd == nil, !wholeFileFits {
            cwd = firstCwd(in: handle, from: UInt64(transcriptWindow), to: UInt64(max(0, size - Int64(transcriptWindow))))
        }

        return TranscriptSummary(
            title: title ?? untitledTranscript,
            cwd: cwd,
            recordCount: countingRecords
                ? countRecords(at: url, size: size, wholeFile: wholeFileFits ? head : nil,
                               tail: wholeFileFits ? head : tail)
                : 0,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            byteSize: size)
    }

    /// Records that say nothing about when the conversation was last active: everything but
    /// what the person typed and what Claude said or did. A command's echo or a task's
    /// notification arrives as the person's turn, but nobody was there.
    static func isMessage(_ record: JSONValue) -> Bool {
        if TranscriptScanner.queuedPrompt(record) != nil { return true }
        guard record["isMeta"]?.boolValue != true, record["isCompactSummary"]?.boolValue != true,
              let message = record["message"] else { return false }
        switch record["type"]?.stringValue {
        case "assistant":
            return (message["content"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "tool_use" }
                || !ConversationText.plainText(of: message).isEmpty
        case "user":
            return InjectedContext.typedText(InjectedContext.parts(ofBlocks: ConversationText.textBlocks(of: message))) != nil
                || !ConversationText.attachmentNames(of: message).isEmpty
        default:
            return false
        }
    }

    /// Walk the tail backwards for the last message's time and the folder last worked in.
    static func scanTail(_ lines: [Data], timestamps: TimestampParser) -> TranscriptFields {
        var fields = TranscriptFields()
        for line in lines.reversed() {
            guard let record = try? JSONValue.parse(line) else { continue }
            let stamp = timestamps.date(from: record["timestamp"]?.stringValue)
            if let stamp {
                if fields.lastTimestamp == nil { fields.lastTimestamp = stamp }
                fields.firstTimestamp = stamp
                if fields.lastMessageTimestamp == nil, isMessage(record) { fields.lastMessageTimestamp = stamp }
            }
            if fields.cwd == nil, let value = record["cwd"]?.stringValue, !value.isEmpty { fields.cwd = value }
            if fields.lastMessageTimestamp != nil, fields.cwd != nil { break }
        }
        return fields
    }

    /// Walk the head forwards for the opening `cwd` and the earliest timestamp, and the last
    /// message's time for a file the head holds whole.
    static func scanHead(_ lines: [Data], timestamps: TimestampParser) -> TranscriptFields {
        var fields = TranscriptFields()
        for line in lines {
            guard let record = try? JSONValue.parse(line), case .object = record else { continue }
            if fields.cwd == nil, let value = record["cwd"]?.stringValue, !value.isEmpty {
                fields.cwd = value
            }
            if let stamp = timestamps.date(from: record["timestamp"]?.stringValue) {
                if fields.firstTimestamp == nil { fields.firstTimestamp = stamp }
                fields.lastTimestamp = stamp
                if isMessage(record) { fields.lastMessageTimestamp = stamp }
            }
        }
        return fields
    }

    /// The first `cwd` between the two windows, for a transcript whose ends name none.
    /// Lines are filtered on their raw bytes, so only the ones that could hold it are parsed.
    static func firstCwd(in handle: FileHandle, from start: UInt64, to end: UInt64) -> String? {
        guard start < end, (try? handle.seek(toOffset: start)) != nil else { return nil }
        let marker = Data("\"cwd\"".utf8)
        var offset = start
        var carry = Data()
        while offset < end, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            var lines = splitLines(carry + chunk)
            carry = lines.popLast() ?? Data()
            for line in lines where line.range(of: marker) != nil {
                if let value = (try? JSONValue.parse(line))?["cwd"]?.stringValue, !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func splitLines(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Data($0) }
    }

    /// Exact record count by counting newlines.
    ///
    /// This streams the file in 1 MiB chunks rather than loading it: an exact count is worth
    /// a sequential read, but a 21 MB transcript held in memory to be counted is not.
    static func countRecords(at url: URL, size: Int64, wholeFile: Data?, tail: Data) -> Int {
        guard size > 0 else { return 0 }
        var newlines = 0
        if let wholeFile {
            newlines = countNewlines(wholeFile)
        } else if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                newlines += countNewlines(chunk)
            }
        }
        // A file not ending in a newline has one more record than it has line breaks.
        if let last = tail.last, last != UInt8(ascii: "\n") { newlines += 1 }
        return newlines
    }

    static func countNewlines(_ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            var count = 0
            for byte in raw where byte == UInt8(ascii: "\n") { count += 1 }
            return count
        }
    }

    /// Transcript timestamps are ISO 8601 with fractional seconds, but older records and
    /// hand-edited files omit them, so both spellings are tried.
    final class TimestampParser {
        private let fractional: ISO8601DateFormatter
        private let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(from text: String?) -> Date? {
            guard let text, !text.isEmpty else { return nil }
            return fractional.date(from: text) ?? plain.date(from: text)
        }
    }
}
