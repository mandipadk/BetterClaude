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
    public static func accounts(in store: StoreRef) throws -> [AccountRef] {
        let level1 = (try? FileManager.default.contentsOfDirectory(
            at: store.sessionsRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        let signedIn = signedInAccountId(in: store)
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
                    isSignedIn: signedIn == accountId))
            }
        }
        return result
    }

    // MARK: - Sessions

    /// Sessions in an account, most recently active first.
    ///
    /// A session whose metadata will not parse is dropped rather than thrown, because a
    /// single half-written file — Claude Desktop writes these while it runs — must not make
    /// the other fifty invisible.
    public static func sessions(in account: AccountRef) throws -> [SessionRef] {
        var result: [SessionRef] = []
        for metadataURL in sessionMetadataURLs(inOrg: account.root) {
            guard let document = try? MetadataDocument(contentsOf: metadataURL) else { continue }
            guard let session = makeSession(account: account, metadataURL: metadataURL,
                                            document: document) else { continue }
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
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .standardizedFileURL
        }
        return homeDirectory().appendingPathComponent(".claude", isDirectory: true)
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
    public static func claudeCodeSessions(projectDir: URL, configDir: URL) throws -> [CCSessionRef] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let timestamps = TimestampParser()

        var result: [CCSessionRef] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where StoreLayout.isTranscriptFileName(url.lastPathComponent) {
            guard let summary = summarizeTranscript(at: url, timestamps: timestamps) else { continue }
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
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func applicationSupportDirectory() -> URL {
        homeDirectory()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    static func applicationDirectories() -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         homeDirectory().appendingPathComponent("Applications", isDirectory: true)]
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
        let home = NSHomeDirectory()
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
                            document: MetadataDocument) -> SessionRef? {
        let filenameStem = String(metadataURL.lastPathComponent.dropLast(5))
        let sessionId = document.sessionId ?? filenameStem
        // Without the transcript's own id there is nothing to look up and nothing to
        // transfer, so this is the one field whose absence disqualifies a session.
        guard let cliSessionId = document.cliSessionId, !cliSessionId.isEmpty else { return nil }

        let cwd = document.cwd ?? ""
        let workspaceURL = metadataURL.deletingLastPathComponent()
            .appendingPathComponent(sessionId, isDirectory: true)
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
            byteSize: fileSize(metadataURL) + directorySize(workspaceURL))
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

    static let untitledTranscript = "(session)"

    /// The subset of a transcript this package needs in order to list it.
    struct TranscriptFields {
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var firstUserText: String?
        var cwd: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        var hasTitle: Bool { customTitle != nil || aiTitle != nil || lastPrompt != nil }
    }

    static func summarizeTranscript(at url: URL, timestamps: TimestampParser) -> TranscriptSummary? {
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

        // A window cut mid-record leaves a fragment at the head's end and the tail's start.
        var headLines = splitLines(head)
        if !wholeFileFits, !headLines.isEmpty { headLines.removeLast() }
        var tailLines = splitLines(tail)
        if !tailLines.isEmpty { tailLines.removeFirst() }

        let tailFields = scanTail(tailLines, timestamps: timestamps)
        let headFields = scanHead(headLines, timestamps: timestamps,
                                  exhaustive: wholeFileFits, titleAlreadyFound: tailFields.hasTitle)

        // The tail is later in the file, so its titles are the more recent ones and win.
        let customTitle = tailFields.customTitle ?? headFields.customTitle
        let aiTitle = tailFields.aiTitle ?? headFields.aiTitle
        let lastPrompt = tailFields.lastPrompt ?? headFields.lastPrompt

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        let firstTimestamp = headFields.firstTimestamp ?? tailFields.firstTimestamp ?? modified
        let lastTimestamp = tailFields.lastTimestamp ?? headFields.lastTimestamp ?? firstTimestamp

        return TranscriptSummary(
            title: customTitle ?? aiTitle ?? lastPrompt
                ?? headFields.firstUserText ?? tailFields.firstUserText
                ?? normalized(firstContentString(inRawHead: head)) ?? untitledTranscript,
            cwd: headFields.cwd ?? tailFields.cwd,
            recordCount: countRecords(at: url, size: size, wholeFile: wholeFileFits ? head : nil,
                                      tail: wholeFileFits ? head : tail),
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            byteSize: size)
    }

    /// Walk the tail backwards, parsing as few records as possible.
    ///
    /// The CLI appends a fresh `custom-title` / `ai-title` / `last-prompt` record rather than
    /// rewriting the old one, so the newest title is the last one in the file and a backwards
    /// walk finds it first. Parsing all ~40 records in a 64 KiB tail costs more than the rest
    /// of a listing put together, so lines are filtered by a raw byte search first.
    static func scanTail(_ lines: [Data], timestamps: TimestampParser) -> TranscriptFields {
        var fields = TranscriptFields()

        for line in lines.reversed() {
            guard let record = try? JSONValue.parse(line),
                  let stamp = timestamps.date(from: record["timestamp"]?.stringValue) else { continue }
            fields.lastTimestamp = stamp
            fields.firstTimestamp = stamp
            fields.cwd = record["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            break
        }

        for line in lines.reversed() {
            guard titleMarkers.contains(where: { line.range(of: $0) != nil }),
                  let record = try? JSONValue.parse(line) else { continue }
            if fields.customTitle == nil {
                fields.customTitle = normalized(record["customTitle"]?.stringValue)
            }
            if fields.aiTitle == nil {
                fields.aiTitle = normalized(record["aiTitle"]?.stringValue)
            }
            if fields.lastPrompt == nil {
                fields.lastPrompt = normalized(record["lastPrompt"]?.stringValue)
            }
        }
        return fields
    }

    static let titleMarkers: [Data] = ["\"customTitle\"", "\"aiTitle\"", "\"lastPrompt\""]
        .map { Data($0.utf8) }

    /// Walk the head forwards for the opening `cwd`, the earliest timestamp, and a fallback
    /// title, stopping as soon as all three are settled.
    ///
    /// `exhaustive` disables that early exit for files small enough that the head *is* the
    /// whole file — there the head also holds the title records, and stopping early would
    /// return a title the session has since been renamed away from.
    static func scanHead(_ lines: [Data], timestamps: TimestampParser,
                         exhaustive: Bool, titleAlreadyFound: Bool) -> TranscriptFields {
        var fields = TranscriptFields()
        for line in lines {
            guard let record = try? JSONValue.parse(line), case .object = record else { continue }
            if let value = normalized(record["customTitle"]?.stringValue) { fields.customTitle = value }
            if let value = normalized(record["aiTitle"]?.stringValue) { fields.aiTitle = value }
            if let value = normalized(record["lastPrompt"]?.stringValue) { fields.lastPrompt = value }
            if fields.cwd == nil, let value = record["cwd"]?.stringValue, !value.isEmpty {
                fields.cwd = value
            }
            if let stamp = timestamps.date(from: record["timestamp"]?.stringValue) {
                if fields.firstTimestamp == nil { fields.firstTimestamp = stamp }
                fields.lastTimestamp = stamp
            }
            if fields.firstUserText == nil, let text = userMessageText(record) {
                fields.firstUserText = normalized(text)
            }
            guard !exhaustive else { continue }
            let titled = titleAlreadyFound || fields.hasTitle || fields.firstUserText != nil
            if titled, fields.cwd != nil, fields.firstTimestamp != nil { break }
        }
        return fields
    }

    static func splitLines(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Data($0) }
    }

    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let flattened = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? nil : flattened
    }

    /// Text of a `type:"user"` record, skipping meta records and records whose content is
    /// only a tool result — both are machine chatter and make useless titles.
    static func userMessageText(_ record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "user" else { return nil }
        guard record["isMeta"]?.boolValue != true else { return nil }
        guard let content = record["message"]?["content"] else { return nil }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return nil }
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text": if let text = block["text"]?.stringValue { return text }
            case "tool_result": return nil
            default: continue
            }
        }
        return nil
    }

    /// Last resort: pull the first `"content":"…"` out of the raw head.
    ///
    /// This exists for transcripts whose opening records this package does not recognize at
    /// all. It decodes only the common escapes — a `\u` sequence survives verbatim — which
    /// is acceptable because by the time this runs the alternative is the literal
    /// `(session)`.
    static func firstContentString(inRawHead head: Data) -> String? {
        let text: String
        if let decoded = String(data: head, encoding: .utf8) {
            text = decoded
        } else if let decoded = String(data: head, encoding: .isoLatin1) {
            text = decoded
        } else {
            return nil
        }
        guard let marker = text.range(of: "\"content\":\"") else { return nil }

        var out = ""
        var index = marker.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                switch text[next] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(text[next])
                }
                index = text.index(after: next)
                continue
            }
            if character == "\"" { break }
            out.append(character)
            index = text.index(after: index)
        }
        return out.isEmpty ? nil : out
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
