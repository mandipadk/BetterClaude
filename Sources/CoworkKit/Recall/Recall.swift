import Foundation

/// Which accounts' history each account's Claude may read.
///
/// Every Claude sees its own account's conversations. Seeing another account's is a door the
/// person opens explicitly, in one direction: letting the work Claude read personal history
/// doesn't let the personal Claude read work history.
public struct RecallAccess: Codable, Sendable, Equatable {
    public var version = 1
    /// Consumer account id → other account ids it may read.
    public var doors: [String: [String]] = [:]
    /// Claude Desktop data folders → the account each is signed into. A server started by a
    /// Desktop copy (which says so in `CLAUDE_USER_DATA_DIR`) answers for that copy's account
    /// even if its settings were copied from another Claude.
    public var installAccounts: [String: String]? = nil

    public init() {}

    public static func url(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Recall/access.json")
    }

    public static func load(paths: HostPaths = .current) -> RecallAccess {
        guard let data = try? Data(contentsOf: url(paths: paths)),
              let access = try? JSONDecoder().decode(RecallAccess.self, from: data) else { return RecallAccess() }
        return access
    }

    public func save(paths: HostPaths = .current) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = Self.url(paths: paths)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWrite.write(try encoder.encode(self), to: target)
    }

    /// The account a server should answer for: the Desktop copy that started it, when the
    /// environment names one this Mac knows, otherwise the account it was registered with.
    public func consumer(registered: String?, environment: [String: String]) -> String? {
        if let dataDir = environment["CLAUDE_USER_DATA_DIR"], !dataDir.isEmpty,
           let account = installAccounts?[URL(fileURLWithPath: dataDir).standardizedFileURL.path] {
            return account
        }
        return registered
    }

    public func allowed(for account: String) -> Set<String> {
        Set([account] + (doors[account] ?? []))
    }

    public func isOpen(from consumer: String, to other: String) -> Bool {
        doors[consumer]?.contains(other) ?? false
    }

    public mutating func setDoor(from consumer: String, to other: String, open: Bool) {
        var list = doors[consumer] ?? []
        list.removeAll { $0 == other }
        if open { list.append(other) }
        doors[consumer] = list.isEmpty ? nil : list.sorted()
    }
}

/// The history tools Claude calls through Better Claude's MCP server, answered from the
/// index, as plain text written for a model to read.
public struct Recall: Sendable {
    public let index: HistoryIndex
    /// Accounts whose conversations may be read.
    public let accounts: Set<String>

    public init(index: HistoryIndex, accounts: Set<String>) {
        self.index = index
        self.accounts = accounts
    }

    static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func stamp(_ date: Date?) -> String {
        date.map { dayFormat.string(from: $0) } ?? "unknown date"
    }

    static func link(_ sessionID: String?) -> String {
        sessionID.map { "betterclaude://conversation/\($0)" } ?? ""
    }

    // MARK: search_history

    public func search(query: String, project: String?, sinceDays: Int?, limit: Int) async throws -> String {
        var options = HistorySearch.Options(accountIDs: accounts, includeAbsent: true,
                                            limit: max(1, min(limit, 20)), excerptsPerHit: 3)
        options.since = sinceDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var hits = try await index.search(query, options: options)
        if let project, !project.isEmpty {
            hits = hits.filter { ($0.projectPath ?? "").localizedCaseInsensitiveContains(project) }
        }
        guard !hits.isEmpty else {
            return "No past conversation matches \"\(query)\". Try fewer or different words; every word has to appear somewhere in a conversation."
        }
        var out = "\(hits.count) past conversation\(hits.count == 1 ? "" : "s") match \"\(query)\", best first.\n"
        for (number, hit) in hits.enumerated() {
            out += "\n\(number + 1). \(hit.title)\n"
            out += "   id: \(hit.sessionID ?? hit.conversationID)\n"
            out += "   last active: \(Self.stamp(hit.lastActivity))"
            out += ", \(hit.place)"
            if let project = hit.projectPath { out += ", in \(project)" }
            if !hit.isPresent { out += " (Claude has since deleted it; Better Claude still has its text)" }
            out += "\n   matching messages: \(hit.matchingMessages)\n"
            for excerpt in hit.excerpts {
                out += "   - message \(excerpt.ordinal), \(Self.speaker(excerpt.role, excerpt.kind)): \(excerpt.text)\n"
            }
        }
        out += "\nRead one with read_conversation, passing its id and, to start near a match, the message number."
        return out
    }

    // MARK: read_conversation

    public func read(id: String, from start: Int?, limit: Int, maxCharacters: Int = 24_000) async throws -> String {
        guard let conversation = try await find(id) else {
            return "There's no conversation with id \(id) that this Claude may read."
        }
        let first = max(0, start ?? 0)
        let messages = try await index.messages(in: conversation.id, from: first, limit: max(1, min(limit, 120)))
        var out = "\(conversation.title)\n"
        out += "id: \(conversation.sessionID ?? id)\n"
        out += "last active: \(Self.stamp(conversation.lastActivity))"
        if let project = conversation.projectPath { out += ", in \(project)" }
        out += "\nmessages: \(conversation.messageCount)\n"
        if let link = Optional(Self.link(conversation.sessionID)), !link.isEmpty { out += "open in Better Claude: \(link)\n" }
        if first > 0 { out += "(starting at message \(first))\n" }
        var budget = maxCharacters
        var last = first - 1
        for message in messages {
            var text = message.text
            if text.count > 4_000 { text = String(text.prefix(4_000)) + " […message shortened]" }
            let line = "\n[\(message.ordinal)] \(Self.speaker(message.role, message.kind)), \(Self.stamp(message.timestamp)):\n\(text)\n"
            if line.count > budget, last >= first { break }
            out += line
            budget -= line.count
            last = message.ordinal
        }
        if last + 1 < conversation.messageCount {
            out += "\n(\(conversation.messageCount - last - 1) more messages. Continue with start=\(last + 1).)"
        }
        return out
    }

    // MARK: recent_work

    public func recent(project: String?, days: Int, limit: Int) async throws -> String {
        var filters = ["present = 1", "last_activity >= ?"]
        var values: [SQLiteValue] = [.date(Date().addingTimeInterval(-Double(max(1, days)) * 86_400))]
        filters.append("account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
        values += accounts.sorted().map(SQLiteValue.text)
        if let project, !project.isEmpty {
            filters.append("project_path LIKE ?")
            values.append(.text("%\(project)%"))
        }
        values.append(.int(Int64(max(1, min(limit, 30)))))
        guard !accounts.isEmpty else { return "No history is shared with this Claude." }
        let rows = try await index.rows("""
            SELECT c.id, c.session_id, c.title, c.project_path, c.last_activity, c.kind, c.install_name,
                   (SELECT text FROM messages WHERE conversation_id = c.id AND role = 'user' AND kind = 'message'
                    ORDER BY ordinal LIMIT 1),
                   (SELECT text FROM messages WHERE conversation_id = c.id AND kind = 'recap'
                    ORDER BY ordinal DESC LIMIT 1)
            FROM conversations c WHERE \(filters.joined(separator: " AND "))
            ORDER BY c.last_activity DESC LIMIT ?
            """, values)
        guard !rows.isEmpty else { return "No conversations in the last \(days) days\(project.map { " in \($0)" } ?? "")." }
        var out = "Conversations from the last \(days) days, most recent first.\n"
        for row in rows {
            out += "\n- \(row.text(2) ?? "Untitled")\n"
            out += "  id: \(row.text(1) ?? row.text(0) ?? "")\n"
            out += "  last active: \(Self.stamp(row.date(4))), \(HistorySearch.place(kind: row.text(5), install: row.text(6)))"
            if let project = row.text(3) { out += ", in \(project)" }
            out += "\n"
            if let asked = row.text(7) { out += "  first asked: \(Self.clip(asked, 280))\n" }
            if let recap = row.text(8) { out += "  Claude's recap: \(Self.clip(recap, 400))\n" }
        }
        return out
    }

    // MARK: file_history

    public func fileHistory(path: String) async throws -> String {
        guard !accounts.isEmpty else { return "No history is shared with this Claude." }
        // A bare file name matches that name in any folder; a path matches exactly.
        let isBareName = !path.contains("/")
        let match: SQLiteValue = isBareName ? .text("%/" + path) : .text((path as NSString).expandingTildeInPath)
        let rows = try await index.rows("""
            SELECT c.session_id, c.title, t.file_path, GROUP_CONCAT(DISTINCT t.name), COUNT(*),
                   MIN(t.timestamp), MAX(t.timestamp)
            FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
            WHERE t.file_path \(isBareName ? "LIKE" : "=") ?
              AND c.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))
            GROUP BY c.id, t.file_path ORDER BY MAX(t.timestamp) DESC LIMIT 25
            """, [match] + accounts.sorted().map(SQLiteValue.text))
        guard !rows.isEmpty else { return "No past conversation read or changed \(path)." }
        var out = "Conversations that read or changed \(path), most recent first.\n"
        for row in rows {
            out += "\n- \(row.text(1) ?? "Untitled")\n"
            out += "  id: \(row.text(0) ?? "")\n"
            out += "  file: \(row.text(2) ?? path)\n"
            out += "  tools: \(row.text(3) ?? "") (\(row.int(4)) times), \(Self.stamp(row.date(5))) to \(Self.stamp(row.date(6)))\n"
        }
        return out
    }

    // MARK: Helpers

    struct Found {
        let id: String
        let sessionID: String?
        let title: String
        let projectPath: String?
        let lastActivity: Date?
        let messageCount: Int
    }

    /// A conversation by session id or index id, only if its account may be read.
    func find(_ id: String) async throws -> Found? {
        guard !accounts.isEmpty else { return nil }
        let rows = try await index.rows("""
            SELECT id, session_id, title, project_path, last_activity, message_count FROM conversations
            WHERE (session_id = ? OR id = ?) AND account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))
            ORDER BY present DESC, message_count DESC, last_activity DESC LIMIT 1
            """, [.text(id), .text(id)] + accounts.sorted().map(SQLiteValue.text))
        guard let row = rows.first else { return nil }
        return Found(id: row.text(0) ?? id, sessionID: row.text(1), title: row.text(2) ?? "Untitled",
                     projectPath: row.text(3), lastActivity: row.date(4), messageCount: Int(row.int(5)))
    }

    static func speaker(_ role: MessageText.Role, _ kind: TranscriptScan.Message.Kind) -> String {
        switch (role, kind) {
        case (_, .recap): return "Claude's recap"
        case (_, .compaction): return "summary of earlier messages"
        case (.user, _): return "the person"
        case (.assistant, _): return "Claude"
        default: return role.rawValue
        }
    }

    static func clip(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
