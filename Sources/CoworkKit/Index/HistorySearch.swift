import Foundation

/// Full-text search over the history index.
///
/// Every word must appear somewhere in a conversation, not necessarily in the same message —
/// that is what people expect of a search box, and it keeps a two-word query from matching
/// everything. Words match as prefixes, so "retr" finds "retry" and "retries".
public enum HistorySearch {

    public struct Options: Sendable {
        /// Only these installs, or every install when `nil`.
        public var installIDs: Set<String>?
        /// Only conversations of these accounts, or every account when `nil`.
        public var accountIDs: Set<String>?
        public var projectPath: String?
        /// Include conversations whose transcript has since been deleted.
        public var includeAbsent = false
        public var since: Date?
        public var limit = 100
        public var excerptsPerHit = 3
        /// When false, a conversation matching some of the words counts, ranked by how many.
        /// For questions in plain language, where not every word will have been said.
        public var requireAllWords = true

        public init(installIDs: Set<String>? = nil, accountIDs: Set<String>? = nil, projectPath: String? = nil,
                    includeAbsent: Bool = false, since: Date? = nil, limit: Int = 100, excerptsPerHit: Int = 3) {
            self.installIDs = installIDs
            self.accountIDs = accountIDs
            self.projectPath = projectPath
            self.includeAbsent = includeAbsent
            self.since = since
            self.limit = limit
            self.excerptsPerHit = excerptsPerHit
        }
    }

    public struct Excerpt: Sendable, Identifiable, Equatable {
        public var id: String { "\(ordinal)" }
        public let ordinal: Int
        public let uuid: String?
        public let role: MessageText.Role
        public let kind: TranscriptScan.Message.Kind
        public let timestamp: Date?
        /// The words around the match, with each match's range for highlighting.
        public let text: String
        public let matches: [Range<String.Index>]
    }

    public struct Hit: Sendable, Identifiable {
        public var id: String { conversationID }
        public let conversationID: String
        public let sessionID: String?
        public let installID: String
        /// What the person calls where it happened: "Claude Code", "Cowork in Claude Work".
        public let place: String
        public let title: String
        public let projectPath: String?
        public let lastActivity: Date?
        public let isPresent: Bool
        public let excerpts: [Excerpt]
        public let matchingMessages: Int
        /// The share of the query's words found in the conversation, from 0 to 1.
        public let coverage: Double
        public let score: Double
    }

    /// The words of a query, lowercased, without FTS syntax.
    public static func terms(in query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "_")))
            .filter { !$0.isEmpty }
    }

    static let openMark = "\u{2}"
    static let closeMark = "\u{3}"

    static func run(_ query: String, options: Options, in database: SQLiteDatabase) throws -> [Hit] {
        let words = terms(in: query)
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " OR ")

        // Which conversations are in scope, with what's needed to rank and show them.
        struct Conversation {
            let sessionID: String?
            let installID: String
            let place: String
            let title: String
            let projectPath: String?
            let lastActivity: Date?
            let isPresent: Bool
        }
        var filters: [String] = []
        var values: [SQLiteValue] = []
        if !options.includeAbsent { filters.append("present = 1") }
        if let installs = options.installIDs {
            guard !installs.isEmpty else { return [] }
            filters.append("install_id IN (\(installs.map { _ in "?" }.joined(separator: ",")))")
            values += installs.sorted().map(SQLiteValue.text)
        }
        if let accounts = options.accountIDs {
            guard !accounts.isEmpty else { return [] }
            filters.append("account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
            values += accounts.sorted().map(SQLiteValue.text)
        }
        if let project = options.projectPath {
            filters.append("project_path = ?")
            values.append(.text(project))
        }
        if let since = options.since {
            filters.append("last_activity >= ?")
            values.append(.date(since))
        }
        let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        var scope: [String: Conversation] = [:]
        for row in try database.rows("""
            SELECT id, session_id, install_id, title, project_path, last_activity, present, kind, install_name
            FROM conversations \(whereClause)
            """, values) {
            scope[row.text(0) ?? ""] = Conversation(sessionID: row.text(1), installID: row.text(2) ?? "",
                                                    place: place(kind: row.text(7), install: row.text(8)),
                                                    title: row.text(3) ?? "", projectPath: row.text(4),
                                                    lastActivity: row.date(5), isPresent: row.int(6) == 1)
        }

        struct Found {
            var words: Set<String> = []
            var messages = 0
            var relevance = 0.0
            var excerpts: [(rank: Double, excerpt: Excerpt)] = []
        }
        var found: [String: Found] = [:]

        let statement = try database.prepare("""
            SELECT m.conversation_id, m.ordinal, m.uuid, m.role, m.kind, m.timestamp,
                   snippet(messages_fts, 0, char(2), char(3), '…', 28), bm25(messages_fts)
            FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ? ORDER BY rank LIMIT 5000
            """)
        try statement.bind([.text(match)])
        while try statement.step() {
            guard let conversationID = statement.text(0), scope[conversationID] != nil else { continue }
            let snippet = statement.text(6) ?? ""
            let (text, ranges, matched) = unmark(snippet)
            var entry = found[conversationID, default: Found()]
            for word in words where matched.contains(where: { $0.hasPrefix(word) }) { entry.words.insert(word) }
            entry.messages += 1
            // bm25 is negative, more negative is better.
            let rank = -statement.double(7)
            entry.relevance += rank
            if entry.excerpts.count < max(options.excerptsPerHit * 4, 12) {
                entry.excerpts.append((rank, Excerpt(
                    ordinal: Int(statement.int(1)), uuid: statement.text(2),
                    role: MessageText.Role(rawValue: statement.text(3) ?? "") ?? .unknown,
                    kind: TranscriptScan.Message.Kind(rawValue: statement.text(4) ?? "") ?? .message,
                    timestamp: statement.isNull(5) ? nil : Date(timeIntervalSince1970: statement.double(5)),
                    text: text, matches: ranges)))
            }
            found[conversationID] = entry
        }

        // Titles count as a match too, and weigh most.
        var titleWords: [String: Set<String>] = [:]
        for (id, conversation) in scope {
            let lowered = conversation.title.lowercased()
            let hits = Set(words.filter { lowered.contains($0) })
            if !hits.isEmpty { titleWords[id] = hits }
        }

        let now = Date()
        var hits: [Hit] = []
        for id in Set(found.keys).union(titleWords.keys) {
            guard let conversation = scope[id] else { continue }
            let entry = found[id] ?? Found()
            let covered = entry.words.union(titleWords[id] ?? [])
            let coverage = Double(covered.count) / Double(max(1, Set(words).count))
            if options.requireAllWords { guard coverage == 1 else { continue } }
            let age = max(0, now.timeIntervalSince(conversation.lastActivity ?? .distantPast)) / 86_400
            let recency = 1 / (1 + age / 30)
            let score = coverage * 12 + Double(titleWords[id]?.count ?? 0) * 8
                + log1p(entry.relevance) * 2 + log1p(Double(entry.messages)) + recency * 2
            let excerpts = entry.excerpts.sorted { $0.rank > $1.rank }
                .prefix(options.excerptsPerHit).map(\.excerpt).sorted { $0.ordinal < $1.ordinal }
            hits.append(Hit(conversationID: id, sessionID: conversation.sessionID,
                            installID: conversation.installID, place: conversation.place, title: conversation.title,
                            projectPath: conversation.projectPath, lastActivity: conversation.lastActivity,
                            isPresent: conversation.isPresent, excerpts: Array(excerpts),
                            matchingMessages: entry.messages, coverage: coverage, score: score))
        }
        return Array(hits.sorted { $0.score == $1.score ? $0.conversationID < $1.conversationID : $0.score > $1.score }
            .prefix(options.limit))
    }

    /// Where a conversation happened, the way a person would say it.
    public static func place(kind: String?, install: String?) -> String {
        switch kind {
        case "cowork": return "Cowork in \(install ?? "Claude")"
        case "codeTab": return "the Code tab in \(install ?? "Claude")"
        default: return "Claude Code"
        }
    }

    /// Strips the snippet's match markers, returning the plain text, where the matches are in
    /// it, and the matched words lowercased.
    static func unmark(_ snippet: String) -> (String, [Range<String.Index>], [String]) {
        var text = ""
        var ranges: [Range<Int>] = []
        var words: [String] = []
        var openAt: Int?
        var count = 0
        var current = ""
        for character in snippet {
            if String(character) == openMark {
                openAt = count
                current = ""
            } else if String(character) == closeMark {
                if let start = openAt { ranges.append(start..<count) }
                words.append(current.lowercased())
                openAt = nil
            } else {
                text.append(character == "\n" ? " " : character)
                if openAt != nil { current.append(character) }
                count += 1
            }
        }
        let indices = Array(text.indices) + [text.endIndex]
        let mapped = ranges.compactMap { range -> Range<String.Index>? in
            guard range.lowerBound < indices.count, range.upperBound < indices.count else { return nil }
            return indices[range.lowerBound]..<indices[range.upperBound]
        }
        return (text, mapped, words)
    }
}
