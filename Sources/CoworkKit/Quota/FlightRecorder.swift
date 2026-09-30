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
    }

    public let replies: [Reply]
    public let compactions: [Date]

    public var totalCost: Double { replies.reduce(0) { $0 + $1.cost } }
    public var peakContext: Int { replies.map(\.context).max() ?? 0 }
    /// The model's context window: 200K, or a million once a conversation went past that.
    public var window: Int { peakContext > 200_000 ? 1_000_000 : 200_000 }
    /// The most expensive replies, most expensive first.
    public var expensive: [Reply] { Array(replies.sorted { $0.cost > $1.cost }.prefix(3)) }
    /// Share of the total the most expensive tenth of replies cost.
    public var topTenthShare: Double {
        guard totalCost > 0, !replies.isEmpty else { return 0 }
        let count = max(1, replies.count / 10)
        return replies.map(\.cost).sorted(by: >).prefix(count).reduce(0, +) / totalCost
    }

    public static func load(conversationID: String, index: HistoryIndex) async throws -> FlightRecord {
        let rows = try await index.rows("""
            SELECT model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h FROM usage
            WHERE conversation_id = ? AND timestamp IS NOT NULL ORDER BY timestamp
            """, [.text(conversationID)])
        let replies = rows.enumerated().compactMap { offset, row -> Reply? in
            guard let model = row.text(0), let time = row.date(1) else { return nil }
            let input = row.int(2), output = row.int(3), read = row.int(4), write5 = row.int(5), write1 = row.int(6)
            return Reply(id: offset, model: model, timestamp: time, context: Int(input + read + write5 + write1),
                         output: Int(output),
                         cost: Pricing.cost(model: model, input: input, output: output, cacheRead: read,
                                            cacheWrite5m: write5, cacheWrite1h: write1))
        }
        let compactions = try await index.rows("""
            SELECT timestamp FROM messages WHERE conversation_id = ? AND kind = 'compaction' AND timestamp IS NOT NULL
            ORDER BY timestamp
            """, [.text(conversationID)]).compactMap { $0.date(0) }
        return FlightRecord(replies: replies, compactions: compactions)
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
        public let percent: Double
        public let threshold: Double
        public let resetsAt: Date?
        /// Another account with more room, and how much it has left.
        public let alternative: (name: String, left: Double)?

        public static func == (a: Alert, b: Alert) -> Bool {
            a.key == b.key && a.percent == b.percent && a.alternative?.name == b.alternative?.name
        }
    }

    public static func due(_ quotas: [AccountQuota], thresholds: [Double] = [80, 95], alreadySent: Set<String>,
                           now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        for quota in quotas where now.timeIntervalSince(quota.asOf) < 2 * 3_600 {
            for kind in [QuotaWindow.Kind.fiveHour, .weekly] {
                guard let window = quota.window(kind) else { continue }
                if let reset = window.resetsAt, reset <= now { continue }
                // Only the highest threshold crossed: 95% says what 80% would have.
                guard let threshold = thresholds.sorted(by: >).first(where: { window.percent >= $0 }) else { continue }
                let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 3_600)) } ?? "open"
                let key = "\(quota.account.id)|\(kind.rawValue)|\(Int(threshold))|\(period)"
                guard !alreadySent.contains(key) else { continue }
                let others = quotas.filter { $0.account.id != quota.account.id && $0.account.id != ClaudeAccount.codex.id }
                    .compactMap { other -> (String, Double)? in
                        let used = [other.window(.fiveHour)?.percent, other.window(.weekly)?.percent].compactMap { $0 }.max()
                        return used.map { (other.account.displayName, max(0, 100 - $0)) }
                    }
                    .filter { $0.1 > max(20, 100 - window.percent) }
                    .max { $0.1 < $1.1 }
                alerts.append(Alert(key: key, account: quota.account.displayName, window: kind, percent: window.percent,
                                    threshold: threshold, resetsAt: window.resetsAt, alternative: others))
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
            let share = Double(last.context) / Double(record.window)
            guard let threshold = thresholds.sorted(by: >).first(where: { share >= $0 }) else { continue }
            // A compaction starts a new stretch: crossing again after it is worth saying again.
            let key = "\(session.sessionID)|\(Int(threshold * 100))|\(record.compactions.count)"
            guard !alreadySent.contains(key) else { continue }
            nudges.append(Nudge(key: key, sessionID: session.sessionID, conversationID: session.conversationID,
                                project: session.project, percent: Int((share * 100).rounded()),
                                context: last.context, window: record.window))
        }
        return nudges
    }
}
