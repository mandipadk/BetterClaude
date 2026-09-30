import Foundation

/// Every conversation on the Mac, indexed on disk: what was said, what it cost, and which
/// files it touched.
///
/// The index is a cache of what Claude keeps, never the only copy of anything, so it can be
/// thrown away and rebuilt at any time. It lives in one SQLite file so that other processes —
/// the command line tool, and the MCP server Claude itself talks to — can read it while the
/// app keeps it current.
public actor HistoryIndex {

    /// Bumped whenever the schema or what gets extracted changes; an older file is rebuilt.
    public static let schemaVersion = 12

    /// One file per schema, so an older copy of the app still running during an update
    /// keeps its own index instead of rebuilding this one back and forth.
    public static func defaultURL(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("history-v\(schemaVersion).sqlite")
    }

    /// Removes indexes written by older versions; they're caches, rebuilt from Claude's files.
    static func removeOlderIndexes(beside url: URL) {
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("history") && !name.hasPrefix(url.lastPathComponent) {
            let stem = name.components(separatedBy: ".sqlite").first ?? name
            let version = Int(stem.replacingOccurrences(of: "history-v", with: "")) ?? 0
            if version < schemaVersion { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    private let database: SQLiteDatabase
    public nonisolated let url: URL?

    /// Opens the index at `url`, creating or rebuilding it as needed; `nil` keeps it in memory.
    public init(url: URL?) throws {
        self.url = url
        var database = try SQLiteDatabase(url: url)
        if let url { Self.removeOlderIndexes(beside: url) }
        if database.userVersion != Self.schemaVersion {
            if let url, database.userVersion != 0 {
                database = try Self.recreate(at: url)
            }
            try Self.createSchema(in: database)
        }
        self.database = database
    }

    public enum OpenError: Error, CustomStringConvertible {
        case missing, outdated
        public var description: String {
            switch self {
            case .missing: return "Better Claude hasn't built its index yet. Open Better Claude once."
            case .outdated: return "Better Claude's index is from another version. Open Better Claude to bring it up to date."
            }
        }
    }

    /// Opens an index another process keeps current, without ever writing to it.
    public init(readingFrom url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpenError.missing }
        let database = try SQLiteDatabase(readOnly: url)
        guard database.userVersion == Self.schemaVersion else { throw OpenError.outdated }
        self.url = url
        self.database = database
    }

    private static func recreate(at url: URL) throws -> SQLiteDatabase {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try SQLiteDatabase(url: url)
    }

    static func createSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            install_id TEXT NOT NULL,
            install_name TEXT,
            account_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            project_path TEXT,
            model TEXT,
            first_activity REAL,
            last_activity REAL,
            source_path TEXT,
            source_size INTEGER NOT NULL DEFAULT 0,
            source_mtime REAL NOT NULL DEFAULT 0,
            indexed_bytes INTEGER NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT 0,
            git_branch TEXT,
            entrypoint TEXT,
            cost_usd REAL,
            lines_added INTEGER,
            lines_removed INTEGER,
            present INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS conversations_session ON conversations(session_id);
        CREATE INDEX IF NOT EXISTS conversations_project ON conversations(project_path);
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            uuid TEXT,
            role TEXT NOT NULL,
            kind TEXT NOT NULL,
            timestamp REAL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, ordinal);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            text, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TABLE IF NOT EXISTS usage (
            conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            model TEXT NOT NULL,
            timestamp REAL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,
            cache_write_5m INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL,
            agent_id TEXT,
            PRIMARY KEY (conversation_id, message_id)
        );
        CREATE INDEX IF NOT EXISTS usage_time ON usage(timestamp);
        CREATE TABLE IF NOT EXISTS tool_calls (
            conversation_id TEXT NOT NULL,
            message_uuid TEXT,
            timestamp REAL,
            name TEXT NOT NULL,
            file_path TEXT,
            detail TEXT,
            agent_id TEXT,
            failed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS tool_calls_conversation ON tool_calls(conversation_id);
        CREATE INDEX IF NOT EXISTS tool_calls_file ON tool_calls(file_path) WHERE file_path IS NOT NULL;
        CREATE TABLE IF NOT EXISTS file_versions (
            conversation_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            version INTEGER NOT NULL,
            backup_file TEXT,
            backup_time REAL,
            message_id TEXT,
            PRIMARY KEY (conversation_id, file_path, version)
        );
        CREATE INDEX IF NOT EXISTS file_versions_path ON file_versions(file_path);
        CREATE TABLE IF NOT EXISTS health (
            conversation_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            detail TEXT,
            timestamp REAL
        );
        CREATE INDEX IF NOT EXISTS health_time ON health(timestamp);
        CREATE TABLE IF NOT EXISTS pull_requests (
            conversation_id TEXT NOT NULL,
            url TEXT NOT NULL,
            number INTEGER,
            repository TEXT,
            timestamp REAL,
            PRIMARY KEY (conversation_id, url)
        );
        CREATE INDEX IF NOT EXISTS pull_requests_number ON pull_requests(number);
        CREATE TABLE IF NOT EXISTS model_markers (
            conversation_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            timestamp REAL
        );
        CREATE INDEX IF NOT EXISTS model_markers_conversation ON model_markers(conversation_id);
        CREATE TABLE IF NOT EXISTS subagents (
            conversation_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            agent_type TEXT,
            requested_model TEXT,
            description TEXT,
            tool_use_id TEXT,
            parent_agent_id TEXT,
            depth INTEGER,
            model TEXT,
            first_activity REAL,
            last_activity REAL,
            replies INTEGER NOT NULL DEFAULT 0,
            tools INTEGER NOT NULL DEFAULT 0,
            prompt TEXT,
            result TEXT,
            source_path TEXT NOT NULL,
            source_size INTEGER NOT NULL,
            source_mtime REAL NOT NULL,
            PRIMARY KEY (conversation_id, agent_id)
        );
        PRAGMA user_version = \(schemaVersion);
        """)
    }

    // MARK: Keeping it current

    struct Stored {
        let sourcePath: String?
        let size: Int64
        let mtime: Double
        let indexedBytes: Int64
        let messageCount: Int64
    }

    /// Brings the index up to date with `snapshot`, reading only transcripts that changed and,
    /// for ones that grew, only what was added. Conversations no longer on disk stay indexed
    /// but are marked absent: Claude Code's cleanup deleting a file shouldn't erase what was
    /// said in it.
    @discardableResult
    public func update(from snapshot: CatalogSnapshot,
                       progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Int {
        var stored: [String: Stored] = [:]
        for row in try database.rows(
            "SELECT id, source_path, source_size, source_mtime, indexed_bytes, message_count FROM conversations") {
            stored[row.text(0) ?? ""] = Stored(sourcePath: row.text(1), size: row.int(2), mtime: row.double(3),
                                               indexedBytes: row.int(4), messageCount: row.int(5))
        }

        struct Job: Sendable {
            let conversation: ConversationRef
            let url: URL
            let size: Int64
            let mtime: Double
            let offset: Int64
            let ordinalStart: Int64
        }
        var jobs: [Job] = []

        try database.transaction {
            let present = Set(snapshot.conversations.map(\.id))
            for id in stored.keys where !present.contains(id) {
                try database.run("UPDATE conversations SET present = 0 WHERE id = ?", [.text(id)])
            }
            for conversation in snapshot.conversations {
                try upsertMetadata(conversation, installName: snapshot.install(conversation.installID)?.name)
                guard let url = conversation.transcriptURL ?? conversation.external?.fileURL else { continue }
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let previous = stored[conversation.id]
                if let previous, previous.sourcePath == url.path,
                   previous.size == size, previous.mtime == mtime { continue }
                var offset: Int64 = 0
                var ordinal: Int64 = 0
                if conversation.external == nil, let previous, previous.sourcePath == url.path,
                   size > previous.indexedBytes, previous.indexedBytes > 0,
                   TranscriptScanner.canResume(url, at: previous.indexedBytes) {
                    offset = previous.indexedBytes
                    ordinal = previous.messageCount
                }
                jobs.append(Job(conversation: conversation, url: url, size: size, mtime: mtime,
                                offset: offset, ordinalStart: ordinal))
            }
        }
        let agentsChanged = try await updateSubagents(snapshot)
        guard !jobs.isEmpty else { return agentsChanged }

        // Parse in parallel off the actor, write back in batches.
        var done = 0
        progress?(Progress(done: 0, total: jobs.count))
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        try await withThrowingTaskGroup(of: (Job, TranscriptScan?).self) { group in
            var iterator = jobs.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let job = iterator.next() else { return }
                inFlight += 1
                group.addTask(priority: .utility) {
                    // Outside sources have formats of their own and are read whole.
                    if let external = job.conversation.external { return (job, try? external.scan()) }
                    return (job, try? TranscriptScanner.scan(job.url, from: job.offset))
                }
            }
            for _ in 0..<limit { addNext() }
            var pending: [(Job, TranscriptScan)] = []
            while inFlight > 0, let (job, scan) = try await group.next() {
                inFlight -= 1
                done += 1
                if let scan { pending.append((job, scan)) }
                if pending.count >= 16 {
                    try await writeBatch(pending.map { ($0.0.conversation, $0.0.url, $0.0.size, $0.0.mtime, $0.0.offset, $0.0.ordinalStart, $0.1) })
                    pending = []
                }
                progress?(Progress(done: done, total: jobs.count))
                if Task.isCancelled { group.cancelAll(); break }
                addNext()
            }
            try await writeBatch(pending.map { ($0.0.conversation, $0.0.url, $0.0.size, $0.0.mtime, $0.0.offset, $0.0.ordinalStart, $0.1) })
        }
        return done
    }

    // MARK: Sub-agents

    /// Sub-agents' transcripts sit beside their conversation's, in `<session>/subagents/`. Each
    /// is read whole when it changes; its usage and tool calls join the conversation's, marked
    /// with the agent, so every total counts them.
    private func updateSubagents(_ snapshot: CatalogSnapshot) async throws -> Int {
        var stored: [String: (Int64, Double)] = [:]
        for row in try database.rows("SELECT source_path, source_size, source_mtime FROM subagents") {
            if let path = row.text(0) { stored[path] = (row.int(1), row.double(2)) }
        }
        struct Job: Sendable { let conversationID: String; let file: Subagents.File; let size: Int64; let mtime: Double }
        var jobs: [Job] = []
        for conversation in snapshot.conversations where conversation.external == nil {
            guard let transcript = conversation.transcriptURL else { continue }
            for file in Subagents.files(beside: transcript) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let previous = stored[file.url.path], previous == (size, mtime) { continue }
                jobs.append(Job(conversationID: conversation.id, file: file, size: size, mtime: mtime))
            }
        }
        guard !jobs.isEmpty else { return 0 }
        let scanned = await withTaskGroup(of: (Job, TranscriptScan?).self) { group in
            for job in jobs { group.addTask(priority: .utility) { (job, try? TranscriptScanner.scan(job.file.url)) } }
            var all: [(Job, TranscriptScan?)] = []
            for await result in group { all.append(result) }
            return all
        }
        try database.transaction {
            for (job, scan) in scanned {
                guard let scan else { continue }
                let id = SQLiteValue.text(job.conversationID)
                let agent = SQLiteValue.text(job.file.agentID)
                try database.run("DELETE FROM usage WHERE conversation_id = ? AND agent_id = ?", [id, agent])
                try database.run("DELETE FROM tool_calls WHERE conversation_id = ? AND agent_id = ?", [id, agent])
                let insertUsage = try database.prepare("""
                    INSERT OR REPLACE INTO usage (conversation_id, message_id, model, timestamp, input, output,
                                                  cache_read, cache_write_5m, cache_write_1h, agent_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                for usage in scan.usage {
                    try insertUsage.run([id, .text(usage.messageID), .text(usage.model), .date(usage.timestamp),
                                         .int(usage.input), .int(usage.output), .int(usage.cacheRead),
                                         .int(usage.cacheWrite5m), .int(usage.cacheWrite1h), agent])
                }
                let insertTool = try database.prepare("""
                    INSERT INTO tool_calls (conversation_id, message_uuid, timestamp, name, file_path, detail, agent_id, failed)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                for call in scan.toolCalls {
                    try insertTool.run([id, .optional(call.messageUUID), .date(call.timestamp), .text(call.name),
                                        .optional(call.filePath), .optional(call.detail), agent, .int(call.failed ? 1 : 0)])
                }
                let prompt = scan.messages.first { $0.role == .user }?.text
                let result = scan.messages.last { $0.role == .assistant }?.text
                let meta = job.file.meta
                try database.run("""
                    INSERT OR REPLACE INTO subagents (conversation_id, agent_id, agent_type, requested_model, description, tool_use_id,
                        parent_agent_id, depth, model, first_activity, last_activity, replies, tools, prompt, result,
                        source_path, source_size, source_mtime)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [id, agent, .optional(meta?.agentType), .optional(meta?.model), .optional(meta?.description), .optional(meta?.toolUseID),
                          .optional(meta?.parentAgentID), meta?.depth.map { .int(Int64($0)) } ?? .null,
                          .optional(scan.usage.last?.model), .date(scan.firstTimestamp), .date(scan.lastTimestamp),
                          .int(Int64(scan.usage.count)), .int(Int64(scan.toolCalls.count)),
                          .optional(prompt.map { String($0.prefix(4_000)) }), .optional(result.map { String($0.prefix(8_000)) }),
                          .text(job.file.url.path), .int(job.size), .double(job.mtime)])
            }
        }
        return scanned.count
    }

    private func writeBatch(_ batch: [(ConversationRef, URL, Int64, Double, Int64, Int64, TranscriptScan)]) throws {
        guard !batch.isEmpty else { return }
        try database.transaction {
            for (conversation, url, size, mtime, offset, ordinalStart, scan) in batch {
                try write(scan, for: conversation, url: url, size: size, mtime: mtime,
                          replacing: offset == 0, ordinalStart: ordinalStart)
            }
        }
    }

    private func upsertMetadata(_ conversation: ConversationRef, installName: String?) throws {
        try database.run("""
            INSERT INTO conversations (id, session_id, install_id, install_name, account_id, kind, title,
                                       project_path, model, last_activity, present)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id,
                install_id = excluded.install_id, install_name = COALESCE(excluded.install_name, install_name),
                account_id = COALESCE(excluded.account_id, account_id),
                kind = excluded.kind, title = excluded.title,
                project_path = excluded.project_path, model = COALESCE(excluded.model, model),
                last_activity = excluded.last_activity, present = 1
            """, [.text(conversation.id), .text(conversation.cliSessionId), .text(conversation.installID),
                  .optional(installName), .optional(conversation.accountID), .text(conversation.kindName), .text(conversation.title), .optional(conversation.projectPath),
                  .optional(conversation.model), .date(conversation.lastActivity)])
    }

    private func write(_ scan: TranscriptScan, for conversation: ConversationRef, url: URL,
                       size: Int64, mtime: Double, replacing: Bool, ordinalStart: Int64) throws {
        let id = SQLiteValue.text(conversation.id)
        if replacing {
            try database.run("DELETE FROM messages WHERE conversation_id = ?", [id])
            // A sub-agent's rows are its own, rewritten when its transcript changes.
            try database.run("DELETE FROM usage WHERE conversation_id = ? AND agent_id IS NULL", [id])
            try database.run("DELETE FROM tool_calls WHERE conversation_id = ? AND agent_id IS NULL", [id])
            try database.run("DELETE FROM file_versions WHERE conversation_id = ?", [id])
            try database.run("DELETE FROM health WHERE conversation_id = ?", [id])
            try database.run("DELETE FROM pull_requests WHERE conversation_id = ?", [id])
            try database.run("DELETE FROM model_markers WHERE conversation_id = ?", [id])
        }
        let insertMessage = try database.prepare("""
            INSERT INTO messages (conversation_id, ordinal, uuid, role, kind, timestamp, text)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        var ordinal = replacing ? 0 : ordinalStart
        for message in scan.messages {
            try insertMessage.run([id, .int(ordinal), .optional(message.uuid), .text(message.role.rawValue),
                                   .text(message.kind.rawValue), .date(message.timestamp), .text(message.text)])
            ordinal += 1
        }
        let insertUsage = try database.prepare("""
            INSERT OR REPLACE INTO usage (conversation_id, message_id, model, timestamp, input, output,
                                          cache_read, cache_write_5m, cache_write_1h)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for usage in scan.usage {
            try insertUsage.run([id, .text(usage.messageID), .text(usage.model), .date(usage.timestamp),
                                 .int(usage.input), .int(usage.output), .int(usage.cacheRead),
                                 .int(usage.cacheWrite5m), .int(usage.cacheWrite1h)])
        }
        let insertTool = try database.prepare("""
            INSERT INTO tool_calls (conversation_id, message_uuid, timestamp, name, file_path, detail, failed)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        for call in scan.toolCalls {
            try insertTool.run([id, .optional(call.messageUUID), .date(call.timestamp), .text(call.name),
                                .optional(call.filePath), .optional(call.detail), .int(call.failed ? 1 : 0)])
        }
        let insertHealth = try database.prepare("""
            INSERT INTO health (conversation_id, kind, name, detail, timestamp) VALUES (?, ?, ?, ?, ?)
            """)
        for event in scan.health {
            try insertHealth.run([id, .text(event.kind.rawValue), .text(event.name), .optional(event.detail),
                                  .date(event.timestamp)])
        }
        // Each snapshot repeats every tracked file; the first record of a version wins.
        let insertVersion = try database.prepare("""
            INSERT OR IGNORE INTO file_versions (conversation_id, file_path, version, backup_file, backup_time, message_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        // Claude Code keys most files relative to the folder the session started in; tool
        // calls name them absolutely, and the two have to meet.
        let root = scan.firstCwd ?? conversation.projectPath
        for version in scan.fileVersions {
            let path = version.path.hasPrefix("/") || root == nil ? version.path
                : URL(fileURLWithPath: root!).appendingPathComponent(version.path).standardizedFileURL.path
            try insertVersion.run([id, .text(path), .int(Int64(version.version)), .optional(version.backupFileName),
                                   .date(version.backupTime), .optional(version.messageID)])
        }
        let insertMarker = try database.prepare("INSERT INTO model_markers (conversation_id, kind, timestamp) VALUES (?, ?, ?)")
        for marker in scan.modelMarkers {
            try insertMarker.run([id, .text(marker.kind.rawValue), .date(marker.timestamp)])
        }
        let insertPull = try database.prepare("""
            INSERT OR IGNORE INTO pull_requests (conversation_id, url, number, repository, timestamp) VALUES (?, ?, ?, ?, ?)
            """)
        for pull in scan.pullRequests {
            try insertPull.run([id, .text(pull.url), pull.number.map { .int(Int64($0)) } ?? .null,
                                .optional(pull.repository), .date(pull.timestamp)])
        }
        let latestModel = scan.usage.last?.model
        try database.run("""
            UPDATE conversations SET source_path = ?, source_size = ?, source_mtime = ?, indexed_bytes = ?,
                message_count = ?,
                first_activity = CASE WHEN ? THEN ? ELSE COALESCE(first_activity, ?) END,
                git_branch = COALESCE(?, git_branch), entrypoint = COALESCE(?, entrypoint),
                model = COALESCE(?, model),
                cost_usd = COALESCE(?, cost_usd), lines_added = COALESCE(?, lines_added),
                lines_removed = COALESCE(?, lines_removed)
            WHERE id = ?
            """, [.text(url.path), .int(size), .double(mtime), .int(scan.endOffset), .int(ordinal),
                  .int(replacing ? 1 : 0), .date(scan.firstTimestamp), .date(scan.firstTimestamp),
                  .optional(scan.gitBranch), .optional(scan.entrypoint), .optional(latestModel),
                  scan.cost.map { .double($0.totalUSD) } ?? .null,
                  .optional(scan.cost?.linesAdded), .optional(scan.cost?.linesRemoved), id])
    }

    // MARK: Reading

    public struct Summary: Sendable, Equatable {
        public var conversations: Int
        public var messages: Int
        public var bytesIndexed: Int64
    }

    public func summary() throws -> Summary {
        let row = try database.rows("""
            SELECT (SELECT COUNT(*) FROM conversations WHERE present = 1),
                   (SELECT COUNT(*) FROM messages),
                   (SELECT COALESCE(SUM(indexed_bytes), 0) FROM conversations)
            """).first
        return Summary(conversations: Int(row?.int(0) ?? 0), messages: Int(row?.int(1) ?? 0),
                       bytesIndexed: row?.int(2) ?? 0)
    }

    /// Searches every message. See ``HistorySearch`` for how a query is read.
    public func search(_ query: String, options: HistorySearch.Options = .init()) throws -> [HistorySearch.Hit] {
        try HistorySearch.run(query, options: options, in: database)
    }

    /// The messages of one conversation, in order.
    public func messages(in conversationID: String, from ordinal: Int = 0,
                         limit: Int = 500) throws -> [IndexedMessage] {
        try database.rows("""
            SELECT ordinal, uuid, role, kind, timestamp, text FROM messages
            WHERE conversation_id = ? AND ordinal >= ? ORDER BY ordinal LIMIT ?
            """, [.text(conversationID), .int(Int64(ordinal)), .int(Int64(limit))]).map(IndexedMessage.init)
    }

    /// Conversations that read or changed `path`, most recent first.
    public func conversations(touching path: String) throws -> [(conversationID: String, tools: [String], last: Date?)] {
        try database.rows("""
            SELECT conversation_id, GROUP_CONCAT(DISTINCT name), MAX(timestamp) FROM tool_calls
            WHERE file_path = ? GROUP BY conversation_id ORDER BY MAX(timestamp) DESC
            """, [.text(path)]).map {
            ($0.text(0) ?? "", ($0.text(1) ?? "").split(separator: ",").map(String.init), $0.date(2))
        }
    }

    /// Runs a read-only query; for the pieces of the app that build their own reports.
    public func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try database.rows(sql, values)
    }
}

public struct IndexedMessage: Sendable, Equatable {
    public let ordinal: Int
    public let uuid: String?
    public let role: MessageText.Role
    public let kind: TranscriptScan.Message.Kind
    public let timestamp: Date?
    public let text: String

    public init(ordinal: Int, uuid: String?, role: MessageText.Role, kind: TranscriptScan.Message.Kind,
                timestamp: Date?, text: String) {
        self.ordinal = ordinal
        self.uuid = uuid
        self.role = role
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
    }

    init(_ row: SQLiteRow) {
        ordinal = Int(row.int(0))
        uuid = row.text(1)
        role = MessageText.Role(rawValue: row.text(2) ?? "") ?? .unknown
        kind = TranscriptScan.Message.Kind(rawValue: row.text(3) ?? "") ?? .message
        timestamp = row.date(4)
        text = row.text(5) ?? ""
    }
}

extension ConversationRef {
    /// How the index names where a conversation came from.
    public var kindName: String {
        switch origin {
        case .cowork: return "cowork"
        case .claudeCode: return "claudeCode"
        case .codeTab: return "codeTab"
        case .external(let conversation): return conversation.source.rawValue
        }
    }
}
