import Foundation

/// A conversation reply by reply: how full the context was, what each reply cost, and where
/// Claude compacted. Answers "why did this conversation use so much" at a glance.
public struct FlightRecord: Sendable, Equatable {

    public struct Reply: Sendable, Identifiable, Equatable {
        public let id: Int
        public let model: String
        public let timestamp: Date
        /// Tokens the model read to write this reply: the whole conversation so far.
        public let context: Int
        public let output: Int
        public let cost: Double
        /// When this reply came after the prompt cache had expired and had to write the
        /// conversation back into it: how long the break was.
        public var afterBreak: TimeInterval? = nil
        /// What rewriting the cache cost beyond reading it, when `afterBreak` is set.
        public var breakExtra: Double? = nil
        /// Copied from the conversation this one was resumed from, where it's counted.
        public var copied = false
    }

    public let replies: [Reply]
    public let compactions: [Date]
    /// What the conversation's sub-agents cost, and how many there were; their replies read
    /// their own context, so they're not in `replies`.
    public var agentCost: Double = 0
    public var agents: Int = 0
    /// What replies copied from the conversation this one was resumed from cost. They're in
    /// `replies`, since the conversation reads with them, but not in `totalCost`: like every
    /// other total, that counts each reply once, where it first appeared.
    public var copiedCost: Double = 0

    /// What the conversation's own replies and its sub-agents' cost.
    public var totalCost: Double { replies.reduce(0) { $0 + ($1.copied ? 0 : $1.cost) } + agentCost }
    /// Replies that first appeared in this conversation.
    public var ownReplies: Int { replies.filter { !$0.copied }.count }
    public var peakContext: Int { replies.map(\.context).max() ?? 0 }
    /// The context window of the model the conversation is on now; a million once it has
    /// gone past 200K, whatever the model.
    public var window: Int { Pricing.contextWindow(for: replies.last?.model ?? "", peak: peakContext) }
    /// The most expensive replies, most expensive first.
    public var expensive: [Reply] { Array(replies.sorted { $0.cost > $1.cost }.prefix(3)) }
    /// Share of the conversation's own replies' cost the most expensive tenth of them made.
    public var topTenthShare: Double {
        let own = replies.reduce(0) { $0 + $1.cost }
        guard own > 0, !replies.isEmpty else { return 0 }
        let count = max(1, replies.count / 10)
        return replies.map(\.cost).sorted(by: >).prefix(count).reduce(0, +) / own
    }

    /// Every reply in the conversation's file, including any copied from the session it was
    /// resumed from: this is the conversation as it reads.
    public static func load(conversationID: String, index: HistoryIndex) async throws -> FlightRecord {
        let rows = try await index.rows("""
            SELECT model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h, is_copy FROM usage
            WHERE conversation_id = ? AND agent_id IS NULL AND timestamp IS NOT NULL ORDER BY timestamp
            """, [.text(conversationID)])
        let breaks = Dictionary(CacheBreaks.detect(conversationID: conversationID, rows: rows).map { ($0.at, $0) },
                                uniquingKeysWith: { first, _ in first })
        let replies = rows.enumerated().compactMap { offset, row -> Reply? in
            guard let model = row.text(0), let time = row.date(1) else { return nil }
            let input = row.int(2), output = row.int(3), read = row.int(4), write5 = row.int(5), write1 = row.int(6)
            return Reply(id: offset, model: model, timestamp: time, context: Int(input + read + write5 + write1),
                         output: Int(output),
                         cost: Pricing.cost(model: model, input: input, output: output, cacheRead: read,
                                            cacheWrite5m: write5, cacheWrite1h: write1),
                         afterBreak: breaks[time]?.gap, breakExtra: breaks[time]?.extra, copied: row.int(7) != 0)
        }
        let compactions = try await index.rows("""
            SELECT timestamp FROM messages WHERE conversation_id = ? AND kind = 'compaction' AND timestamp IS NOT NULL
            ORDER BY timestamp
            """, [.text(conversationID)]).compactMap { $0.date(0) }
        var record = FlightRecord(replies: replies, compactions: compactions)
        record.copiedCost = replies.reduce(0) { $0 + ($1.copied ? $1.cost : 0) }
        for row in try await index.rows("""
            SELECT model, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write_5m), SUM(cache_write_1h), is_copy
            FROM usage WHERE conversation_id = ? AND agent_id IS NOT NULL GROUP BY model, is_copy
            """, [.text(conversationID)]) {
            guard let model = row.text(0) else { continue }
            let cost = Pricing.cost(model: model, input: row.int(1), output: row.int(2), cacheRead: row.int(3),
                                    cacheWrite5m: row.int(4), cacheWrite1h: row.int(5))
            if row.int(6) != 0 { record.copiedCost += cost } else { record.agentCost += cost }
        }
        record.agents = Int(try await index.rows("SELECT COUNT(*) FROM subagents WHERE conversation_id = ?",
                                                 [.text(conversationID)]).first?.int(0) ?? 0)
        return record
    }
}

/// Coming back after the prompt cache expired. Each reply writes the conversation into the
/// cache for five minutes or an hour; after a longer break the next reply writes it all again,
/// at the write price, where it would otherwise have read it for a tenth of that or less.
public enum CacheBreaks {

    public struct Break: Sendable, Equatable {
        public let conversationID: String
        public let at: Date
        public let gap: TimeInterval
        /// Tokens written back into the cache.
        public let tokens: Int64
        /// What writing them cost beyond reading them from the cache, at list prices.
        public let extra: Double
    }

    /// Only conversations this big are worth a word: re-reading a small one costs little.
    static let minimumContext: Int64 = 20_000

    /// What writing tokens into the cache costs beyond reading them from it, at list prices.
    /// Every place that prices a cache break uses this.
    public static func extra(model: String, written5m: Int64, written1h: Int64) -> Double {
        let rate = Pricing.rate(for: model)
        let written = Double(written5m) * 1.25 + Double(written1h) * 2
        return (written - Double(written5m + written1h) * rate.cacheReadFactor) * rate.input / 1_000_000
    }

    /// Breaks in a conversation, from its usage rows: model, timestamp, input, output,
    /// cache read, 5-minute write, 1-hour write, in time order. A row `counts` rejects still
    /// keeps the time, but isn't reported as a break.
    static func detect(conversationID: String, rows: [SQLiteRow],
                       counts: (SQLiteRow) -> Bool = { _ in true }) -> [Break] {
        var found: [Break] = []
        // How the cache was last written decides how long it lasts.
        var hourLong = false
        for index in rows.indices.dropFirst() {
            let previous = rows[index - 1], row = rows[index]
            if previous.int(5) + previous.int(6) > 0 { hourLong = previous.int(6) > 0 }
            guard let then = previous.date(1), let now = row.date(1), let model = row.text(0) else { continue }
            let ttl: TimeInterval = hourLong ? 3_600 : 300
            let gap = now.timeIntervalSince(then)
            let written = row.int(5) + row.int(6)
            let context = row.int(2) + row.int(4) + written
            guard gap > ttl, context >= minimumContext, written * 2 > context, counts(row) else { continue }
            found.append(Break(conversationID: conversationID, at: now, gap: gap, tokens: written,
                               extra: extra(model: model, written5m: row.int(5), written1h: row.int(6))))
        }
        return found
    }

    public struct Summary: Sendable {
        public let breaks: Int
        public let tokens: Int64
        public let extra: Double
        /// Where it happened most, by project folder, costliest first; `path` is `nil` for
        /// conversations outside one.
        public let projects: [(path: String?, name: String, extra: Double, breaks: Int)]
        /// Whether this Mac's sessions mostly keep the cache for an hour, rather than five minutes.
        public let hourLong: Bool
        /// The longest gap, and which conversation it was in.
        public var longest: Break?

        /// Summaries of separate accounts or stretches, as one.
        public static func combined(_ summaries: [Summary]) -> Summary {
            var projects: [String?: (Double, Int)] = [:]
            for project in summaries.flatMap(\.projects) {
                projects[project.path] = ((projects[project.path]?.0 ?? 0) + project.extra,
                                          (projects[project.path]?.1 ?? 0) + project.breaks)
            }
            return Summary(breaks: summaries.reduce(0) { $0 + $1.breaks }, tokens: summaries.reduce(0) { $0 + $1.tokens },
                           extra: summaries.reduce(0) { $0 + $1.extra },
                           projects: named(projects),
                           hourLong: summaries.filter(\.hourLong).count * 2 >= summaries.count,
                           longest: summaries.compactMap(\.longest).max { $0.gap < $1.gap })
        }
    }

    /// Totals by project folder, named, costliest first.
    static func named(_ totals: [String?: (Double, Int)]) -> [(path: String?, name: String, extra: Double, breaks: Int)] {
        let names = Projects.names(for: totals.keys.compactMap { $0 })
        return totals.map { (path: $0.key, name: $0.key.flatMap { names[$0] } ?? "Other", extra: $0.value.0, breaks: $0.value.1) }
            .sorted { $0.extra > $1.extra }
    }

    /// Breaks between `since` and `until`, in these accounts' conversations when given. A reply
    /// copied into a resumed conversation is counted where it first appeared.
    public static func summary(index: HistoryIndex, accountIDs: Set<String>? = nil, since: Date,
                               until: Date = .distantFuture) async throws -> Summary {
        let accounts = DistinctUsage.accounts(accountIDs)
        let rows = accountIDs?.isEmpty == true ? [] : try await index.rows("""
            SELECT u.model, u.timestamp, u.input, u.output, u.cache_read, u.cache_write_5m, u.cache_write_1h,
                   u.conversation_id, c.project_path, u.is_copy
            FROM usage u JOIN conversations c ON c.id = u.conversation_id
            WHERE u.agent_id IS NULL AND u.timestamp >= ? AND u.timestamp < ?\(accounts.sql)
            ORDER BY u.conversation_id, u.timestamp
            """, [.date(since.addingTimeInterval(-3_600)), .date(until)] + accounts.values)
        let original: (SQLiteRow) -> Bool = { $0.int(9) == 0 }
        var all: [Break] = []
        var projectOf: [String: String] = [:]
        var start = 0
        var hourWrites = 0, fiveWrites = 0
        for (index, row) in rows.enumerated() {
            if original(row) {
                if row.int(6) > 0 { hourWrites += 1 } else if row.int(5) > 0 { fiveWrites += 1 }
            }
            let isLast = index == rows.count - 1 || rows[index + 1].text(7) != row.text(7)
            guard isLast, let id = row.text(7) else { continue }
            if let project = row.text(8), !project.isEmpty { projectOf[id] = Projects.root(of: project) }
            all += detect(conversationID: id, rows: Array(rows[start...index]), counts: original)
                .filter { $0.at >= since && $0.at < until }
            start = index + 1
        }
        var byProject: [String?: (Double, Int)] = [:]
        for item in all {
            let path = projectOf[item.conversationID]
            byProject[path] = ((byProject[path]?.0 ?? 0) + item.extra, (byProject[path]?.1 ?? 0) + 1)
        }
        return Summary(breaks: all.count, tokens: all.reduce(0) { $0 + $1.tokens }, extra: all.reduce(0) { $0 + $1.extra },
                       projects: named(byProject),
                       hourLong: hourWrites >= fiveWrites, longest: all.max { $0.gap < $1.gap })
    }

    public struct Expiry: Sendable, Equatable {
        /// When the cache goes cold.
        public let at: Date
        /// Tokens the next reply would have to write again.
        public let context: Int64
        public let model: String
        /// The cache lasts an hour after each reply, rather than five minutes.
        public let hourLong: Bool
        /// What the next reply would cost beyond reading the cache, once it has gone cold.
        public let extra: Double
    }

    /// When a conversation's cache goes cold: an hour or five minutes after its last reply,
    /// depending on how the cache was last written.
    public static func expiry(conversationID: String, index: HistoryIndex) async throws -> Expiry? {
        let rows = try await index.rows("""
            SELECT model, timestamp, input, cache_read, cache_write_5m, cache_write_1h FROM usage
            WHERE conversation_id = ? AND agent_id IS NULL AND timestamp IS NOT NULL ORDER BY timestamp DESC LIMIT 20
            """, [.text(conversationID)])
        guard let row = rows.first, let model = row.text(0), let at = row.date(1) else { return nil }
        let hourLong = rows.first { $0.int(4) + $0.int(5) > 0 }.map { $0.int(5) > 0 } ?? false
        let context = row.int(2) + row.int(3) + row.int(4) + row.int(5)
        return Expiry(at: at.addingTimeInterval(hourLong ? 3_600 : 300), context: context, model: model,
                      hourLong: hourLong,
                      extra: extra(model: model, written5m: hourLong ? 0 : context, written1h: hourLong ? context : 0))
    }
}

/// When to tell someone they're close to a limit: once per threshold per window, only from
/// a fresh reading, naming the account with the most room left.
public enum LimitAlerts {

    public struct Alert: Sendable, Equatable {
        /// Identifies this threshold in this window, so it's posted once.
        public let key: String
        public let account: String
        public let window: QuotaWindow.Kind
        /// What a weekly limit for part of the plan covers, like "Fable".
        public let scope: String?
        public let percent: Double
        public let threshold: Double
        public let resetsAt: Date?
        /// Another account with more room, and how much it has left.
        public let alternative: (name: String, left: Double)?

        public static func == (a: Alert, b: Alert) -> Bool {
            a.key == b.key && a.percent == b.percent && a.alternative?.name == b.alternative?.name
        }
    }

    /// The five-hour limit and whichever weekly limit is closest to full.
    public static func due(_ quotas: [AccountQuota], thresholds: [Double] = [80, 95], alreadySent: Set<String>,
                           now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        for quota in quotas where now.timeIntervalSince(quota.asOf) < 2 * 3_600 {
            for window in [quota.window(.fiveHour), quota.tightestWeekly].compactMap({ $0 }) where !window.isStale {
                if let reset = window.resetsAt, reset <= now { continue }
                // Only the highest threshold crossed: 95% says what 80% would have.
                guard let threshold = thresholds.sorted(by: >).first(where: { window.percent >= $0 }) else { continue }
                // Without a reset time, the five hours the reading falls in stand for the window.
                let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 3_600)) }
                    ?? "p\(Int(quota.asOf.timeIntervalSince1970 / (5 * 3_600)))"
                let name = window.kind == .weeklyScoped ? "\(window.kind.rawValue):\(window.scope ?? "")" : window.kind.rawValue
                let key = "\(quota.account.id)|\(name)|\(Int(threshold))|\(period)"
                guard !alreadySent.contains(key) else { continue }
                let others = quotas.filter { $0.account.id != quota.account.id && $0.account.id != ClaudeAccount.codex.id }
                    .compactMap { other in other.headroom.map { (other.account.displayName, $0) } }
                    .filter { $0.1 > max(20, 100 - window.percent) }
                    .max { $0.1 < $1.1 }
                alerts.append(Alert(key: key, account: quota.account.displayName, window: window.kind, scope: window.scope,
                                    percent: window.percent, threshold: threshold, resetsAt: window.resetsAt,
                                    alternative: others))
            }
        }
        return alerts
    }
}

/// A heads-up while a running session still has room: once it has read most of its context
/// window, each further reply costs more, and compacting or handing off costs least now.
public enum ContextCoach {

    public struct Nudge: Sendable, Equatable {
        /// Identifies this threshold in this stretch of the session, so it's posted once.
        public let key: String
        public let sessionID: String
        public let conversationID: String
        public let project: String
        public let percent: Int
        public let context: Int
        public let window: Int
    }

    public struct Live: Sendable {
        public let sessionID: String
        public let conversationID: String
        public let project: String
        public init(sessionID: String, conversationID: String, project: String) {
            self.sessionID = sessionID
            self.conversationID = conversationID
            self.project = project
        }
    }

    public static func due(_ live: [Live], index: HistoryIndex, thresholds: [Double] = [0.75, 0.9],
                           alreadySent: Set<String>, now: Date = Date()) async throws -> [Nudge] {
        var nudges: [Nudge] = []
        for session in live {
            let record = try await FlightRecord.load(conversationID: session.conversationID, index: index)
            guard let last = record.replies.last, now.timeIntervalSince(last.timestamp) < 20 * 60 else { continue }
            let window = record.window
            let share = Double(last.context) / Double(window)
            guard let threshold = thresholds.sorted(by: >).first(where: { share >= $0 }) else { continue }
            // A compaction starts a new stretch, and a bigger window a new scale: crossing
            // again after either is worth saying again.
            let key = "\(session.sessionID)|\(window)|\(Int(threshold * 100))|\(record.compactions.count)"
            guard !alreadySent.contains(key) else { continue }
            nudges.append(Nudge(key: key, sessionID: session.sessionID, conversationID: session.conversationID,
                                project: session.project, percent: Int((share * 100).rounded()),
                                context: last.context, window: window))
        }
        return nudges
    }
}
