import Foundation

/// Full-text search over the history index.
///
/// Every word must appear somewhere in a conversation, not necessarily in the same message —
/// that is what people expect of a search box, and it keeps a two-word query from matching
/// everything. Words match as prefixes, so "retr" finds "retry" and "retries", and without
/// regard to accents, so "cafe" finds "café". Words joined by punctuation, like `retry_cap`,
/// have to appear together.
public enum HistorySearch {

    public struct Options: Sendable {
        /// Only these installs, or every install when `nil`.
        public var installIDs: Set<String>?
        /// Only conversations of these accounts, or every account when `nil`.
        public var accountIDs: Set<String>?
        public var projectPath: String?
        /// Only conversations whose project folder contains this text.
        public var projectContaining: String?
        /// Include conversations whose transcript has since been deleted.
        public var includeAbsent = false
        public var since: Date?
        public var limit = 100
        public var excerptsPerHit = 3
        /// When false, a conversation matching some of the words counts, ranked by how many.
        /// For questions in plain language, where not every word will have been said.
        public var requireAllWords = true
        /// Hide keys and tokens in excerpts, for what a model reads.
        public var redactSecrets = false

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

    /// The words of a query, lowercased and without accents, split the way the index splits
    /// text: at anything that isn't a letter or a digit, underscores included.
    public static func terms(in query: String) -> [String] {
        tokens(in: query).map(\.folded)
    }

    /// What has to appear for a query to match: each run of non-space characters, as the
    /// index's words in order. "retry_cap" is one phrase of two words, "retry cap" two phrases.
    static func phrases(in query: String) -> [[String]] {
        var seen = Set<[String]>()
        return query.split(whereSeparator: \.isWhitespace).compactMap { chunk -> [String]? in
            let words = terms(in: String(chunk))
            guard !words.isEmpty, seen.insert(words).inserted else { return nil }
            return words
        }
    }

    /// Words as the index's `unicode61 remove_diacritics 2` tokenizer sees them: runs of
    /// letters and digits, lowercased, accents removed.
    static func tokens(in text: String) -> [(folded: String, range: Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if let from = start {
                out.append((fold(text[from..<index]), from..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let from = start { out.append((fold(text[from...]), from..<text.endIndex)) }
        return out
    }

    static func fold(_ word: Substring) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// An FTS5 expression matching `phrase`, its last word as a prefix.
    static func expression(_ phrase: [String]) -> String {
        "\"" + phrase.joined(separator: " ") + "\"*"
    }

    /// Whether `phrase` appears in `words`, its last word as a prefix.
    static func contains(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        return (0...(words.count - phrase.count)).contains { start in
            starts(phrase, in: words, at: start)
        }
    }

    static func starts(_ phrase: [String], in words: [String], at start: Int) -> Bool {
        guard start + phrase.count <= words.count else { return false }
        return phrase.indices.allSatisfy { offset in
            let word = words[start + offset]
            return offset == phrase.count - 1 ? word.hasPrefix(phrase[offset]) : word == phrase[offset]
        }
    }

    static let openMark = "\u{2}"
    static let closeMark = "\u{3}"

    static func run(_ query: String, options: Options, in database: SQLiteDatabase) throws -> [Hit] {
        let phrases = phrases(in: query)
        guard !phrases.isEmpty else { return [] }
        let anyPhrase = phrases.map(expression).joined(separator: " OR ")

        // Which conversations are in scope: part of every query, so nothing out of scope takes
        // a place among the results.
        var filters: [String] = []
        var values: [SQLiteValue] = []
        if !options.includeAbsent { filters.append("c.present = 1") }
        if let installs = options.installIDs {
            guard !installs.isEmpty else { return [] }
            filters.append("c.install_id IN (\(installs.map { _ in "?" }.joined(separator: ",")))")
            values += installs.sorted().map(SQLiteValue.text)
        }
        if let accounts = options.accountIDs {
            guard !accounts.isEmpty else { return [] }
            filters.append("c.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
            values += accounts.sorted().map(SQLiteValue.text)
        }
        if let project = options.projectPath {
            filters.append("c.project_path = ?")
            values.append(.text(project))
        }
        if let fragment = options.projectContaining, !fragment.isEmpty {
            filters.append("c.project_path LIKE ? ESCAPE '\\'")
            values.append(.like("%", fragment, "%"))
        }
        if let since = options.since {
            filters.append("c.last_activity >= ?")
            values.append(.date(since))
        }
        let scope = filters.map { " AND " + $0 }.joined()

        struct Conversation {
            let sessionID: String?
            let installID: String
            let place: String
            let title: String
            let projectPath: String?
            let lastActivity: Date?
            let isPresent: Bool
        }
        var conversations: [String: Conversation] = [:]
        for row in try database.rows("""
            SELECT c.id, c.session_id, c.install_id, c.title, c.project_path, c.last_activity, c.present, c.kind,
                   c.install_name
            FROM conversations c WHERE 1 = 1\(scope)
            """, values) {
            conversations[row.text(0) ?? ""] = Conversation(
                sessionID: row.text(1), installID: row.text(2) ?? "", place: place(kind: row.text(7), install: row.text(8)),
                title: row.text(3) ?? "", projectPath: row.text(4), lastActivity: row.date(5), isPresent: row.int(6) == 1)
        }

        // The FTS table drives each query, so a word costs one pass over its matches.
        let matching = """
            FROM messages_fts CROSS JOIN messages m ON m.id = messages_fts.rowid
            CROSS JOIN conversations c ON c.id = m.conversation_id
            WHERE messages_fts MATCH ?\(scope)
            """

        struct Found {
            var phrases: Set<Int> = []
            var messages = 0
            var relevance = 0.0
        }
        // Messages matching any word: how many, and how well (bm25 is negative, more negative
        // is better).
        var found: [String: Found] = [:]
        for row in try database.rows("""
            SELECT m.conversation_id, COUNT(*), SUM(messages_fts.rank) \(matching) GROUP BY m.conversation_id
            """, [.text(anyPhrase)] + values) {
            guard let id = row.text(0) else { continue }
            found[id] = Found(phrases: phrases.count == 1 ? [0] : [], messages: Int(row.int(1)), relevance: -row.double(2))
        }
        // Which words each conversation has, anywhere in any of its messages.
        if phrases.count > 1 {
            for (number, phrase) in phrases.enumerated() {
                for row in try database.rows("SELECT DISTINCT m.conversation_id \(matching)",
                                             [.text(expression(phrase))] + values) {
                    if let id = row.text(0) { found[id]?.phrases.insert(number) }
                }
            }
        }

        // Titles count as a match too, and weigh most.
        var inTitle: [String: Set<Int>] = [:]
        for (id, conversation) in conversations {
            let words = terms(in: conversation.title)
            let hits = Set(phrases.indices.filter { contains(phrases[$0], in: words) })
            if !hits.isEmpty { inTitle[id] = hits }
        }

        struct Ranked {
            let id: String
            let found: Found
            let coverage: Double
            let score: Double
        }
        let now = Date()
        var ranked: [Ranked] = []
        for id in Set(found.keys).union(inTitle.keys) {
            guard let conversation = conversations[id] else { continue }
            let entry = found[id] ?? Found()
            let titled = inTitle[id] ?? []
            let coverage = Double(entry.phrases.union(titled).count) / Double(phrases.count)
            if options.requireAllWords { guard coverage == 1 else { continue } }
            let age = max(0, now.timeIntervalSince(conversation.lastActivity ?? .distantPast)) / 86_400
            let recency = 1 / (1 + age / 30)
            let score = coverage * 12 + Double(titled.count) * 8
                + log1p(entry.relevance) * 2 + log1p(Double(entry.messages)) + recency * 2
            ranked.append(Ranked(id: id, found: entry, coverage: coverage, score: score))
        }
        let best = ranked.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(options.limit)

        let excerpts = try self.excerpts(for: best.filter { $0.found.messages > 0 }.map(\.id), phrases: phrases,
                                         anyPhrase: anyPhrase, options: options, in: database)
        return best.compactMap { entry in
            guard let conversation = conversations[entry.id] else { return nil }
            return Hit(conversationID: entry.id, sessionID: conversation.sessionID,
                       installID: conversation.installID, place: conversation.place, title: conversation.title,
                       projectPath: conversation.projectPath, lastActivity: conversation.lastActivity,
                       isPresent: conversation.isPresent, excerpts: excerpts[entry.id] ?? [],
                       matchingMessages: entry.found.messages, coverage: entry.coverage, score: entry.score)
        }
    }

    /// Each conversation's best-matching messages, in the order they were said.
    static func excerpts(for ids: [String], phrases: [[String]], anyPhrase: String, options: Options,
                         in database: SQLiteDatabase) throws -> [String: [Excerpt]] {
        let wanted = options.excerptsPerHit
        guard wanted > 0, !ids.isEmpty else { return [:] }
        var best: [String: [(rank: Double, rowid: Int64)]] = [:]
        for row in try database.rows("""
            SELECT m.conversation_id, m.id, messages_fts.rank
            FROM messages_fts CROSS JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ? AND m.conversation_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, [.text(anyPhrase)] + ids.map(SQLiteValue.text)) {
            guard let id = row.text(0) else { continue }
            var list = best[id, default: []]
            list.append((row.double(2), row.int(1)))
            if list.count > wanted * 4 {
                list.sort { $0.rank < $1.rank }
                list.removeLast(list.count - wanted)
            }
            best[id] = list
        }
        let chosen = best.values.flatMap { $0.sorted { $0.rank < $1.rank }.prefix(wanted).map(\.rowid) }
        guard !chosen.isEmpty else { return [:] }
        // A key can straddle where the index would cut a snippet, leaving a tail no pattern
        // recognises, so redacted excerpts are cut from the whole message once its keys are hidden.
        let columns = "m.conversation_id, m.ordinal, m.uuid, m.role, m.kind, m.timestamp"
        let list = chosen.map { _ in "?" }.joined(separator: ",")
        // Filtered on the messages side: a rowid constraint on the FTS table would run the
        // whole query again for each row, which for a short prefix means thousands of words.
        let rows = options.redactSecrets
            ? try database.rows("SELECT \(columns), m.text FROM messages m WHERE m.id IN (\(list))", chosen.map(SQLiteValue.int))
            : try database.rows("""
                SELECT \(columns), snippet(messages_fts, 0, char(2), char(3), '…', 28)
                FROM messages_fts CROSS JOIN messages m ON m.id = messages_fts.rowid
                WHERE messages_fts MATCH ? AND m.id IN (\(list))
                """, [.text(anyPhrase)] + chosen.map(SQLiteValue.int))
        var out: [String: [Excerpt]] = [:]
        for row in rows {
            guard let id = row.text(0) else { continue }
            let (text, ranges) = options.redactSecrets
                ? excerpt(of: SecretSweep.redact(row.text(6) ?? ""), phrases: phrases)
                : unmark(row.text(6) ?? "")
            out[id, default: []].append(Excerpt(
                ordinal: Int(row.int(1)), uuid: row.text(2),
                role: MessageText.Role(rawValue: row.text(3) ?? "") ?? .unknown,
                kind: TranscriptScan.Message.Kind(rawValue: row.text(4) ?? "") ?? .message,
                timestamp: row.date(5), text: text, matches: ranges))
        }
        return out.mapValues { $0.sorted { $0.ordinal < $1.ordinal } }
    }

    /// About `width` words of `text` around its first match, with where each match is: what
    /// the index's snippets give, cut from text the index never saw.
    static func excerpt(of text: String, phrases: [[String]], width: Int = 28) -> (String, [Range<String.Index>]) {
        let words = tokens(in: text)
        guard !words.isEmpty else { return (String(text.prefix(200).map { $0.isNewline ? " " : $0 }), []) }
        let folded = words.map(\.folded)
        var spans: [Range<Int>] = []
        var at = 0
        while at < folded.count {
            if let phrase = phrases.first(where: { starts($0, in: folded, at: at) }) {
                spans.append(at..<(at + phrase.count))
                at += phrase.count
            } else {
                at += 1
            }
        }
        let first = max(0, min((spans.first?.lowerBound ?? 0) - width / 4, words.count - width))
        let last = min(words.count, first + width)
        let lower = words[first].range.lowerBound
        let upper = words[last - 1].range.upperBound
        let lead = first > 0 ? "…" : ""
        let excerpt = lead + String(text[lower..<upper].map { $0.isNewline ? " " : $0 }) + (last < words.count ? "…" : "")
        let positions = Array(excerpt.indices) + [excerpt.endIndex]
        let ranges = spans.filter { $0.lowerBound >= first && $0.upperBound <= last }.compactMap { span -> Range<String.Index>? in
            let start = lead.count + text.distance(from: lower, to: words[span.lowerBound].range.lowerBound)
            let end = lead.count + text.distance(from: lower, to: words[span.upperBound - 1].range.upperBound)
            guard start <= end, end < positions.count else { return nil }
            return positions[start]..<positions[end]
        }
        return (excerpt, ranges)
    }

    /// Where a conversation happened, the way a person would say it.
    public static func place(kind: String?, install: String?) -> String {
        switch kind {
        case "cowork": return "Cowork in \(install ?? "Claude")"
        case "codeTab": return "the Code tab in \(install ?? "Claude")"
        case "claudeWeb": return "claude.ai"
        case "codex": return "Codex"
        case "otherMac": return install ?? "another Mac"
        default: return "Claude Code"
        }
    }

    /// Strips the snippet's match markers, returning the plain text and where the matches are
    /// in it.
    static func unmark(_ snippet: String) -> (String, [Range<String.Index>]) {
        var text = ""
        var ranges: [Range<Int>] = []
        var openAt: Int?
        var count = 0
        for character in snippet {
            if String(character) == openMark {
                openAt = count
            } else if String(character) == closeMark {
                if let start = openAt { ranges.append(start..<count) }
                openAt = nil
            } else {
                text.append(character.isNewline ? " " : character)
                count += 1
            }
        }
        let indices = Array(text.indices) + [text.endIndex]
        let mapped = ranges.compactMap { range -> Range<String.Index>? in
            guard range.lowerBound < indices.count, range.upperBound < indices.count else { return nil }
            return indices[range.lowerBound]..<indices[range.upperBound]
        }
        return (text, mapped)
    }
}

extension SQLiteValue {
    /// A pattern for `LIKE ? ESCAPE '\'` in which `literal` matches only itself, its `%`, `_`
    /// and `\` included.
    public static func like(_ before: String, _ literal: String, _ after: String) -> SQLiteValue {
        let escaped = literal.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return .text(before + escaped + after)
    }
}
