import Foundation
import Testing

@testable import CoworkKit

/// An in-memory index holding only conversations and their usage rows.
private struct UsageIndex {
    let index: HistoryIndex

    init() throws { index = try HistoryIndex(url: nil) }

    func conversation(_ id: String, account: String, started: Date, project: String = "/srv/app") async throws {
        _ = try await index.rows("""
            INSERT INTO conversations (id, install_id, account_id, kind, title, project_path, first_activity, last_activity)
            VALUES (?, 'cli', ?, 'claude-code', ?, ?, ?, ?)
            """, [.text(id), .text(account), .text("Conversation \(id)"), .text(project), .date(started), .date(started)])
    }

    func reply(_ conversation: String, _ message: String, at: Date, model: String = "claude-opus-5",
               input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, write5m: Int64 = 0, write1h: Int64 = 0) async throws {
        _ = try await index.rows("""
            INSERT INTO usage (conversation_id, message_id, model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(conversation), .text(message), .text(model), .date(at), .int(input), .int(output), .int(read),
                  .int(write5m), .int(write1h)])
    }
}

@Suite("Usage accuracy")
struct UsageAccuracyTests {

    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("A reply copied into a resumed conversation counts once in totals, and fully in its own conversation")
    func copiedRepliesCountOnce() async throws {
        let usage = try UsageIndex()
        let start = Self.start
        try await usage.conversation("original", account: "a", started: start)
        try await usage.conversation("resumed", account: "a", started: start.addingTimeInterval(3_600))
        // The resumed session's file starts with the original's replies, same ids and times.
        for conversation in ["original", "resumed"] {
            try await usage.reply(conversation, "m1", at: start.addingTimeInterval(60), output: 1_000_000)
            try await usage.reply(conversation, "m2", at: start.addingTimeInterval(120), output: 1_000_000)
        }
        try await usage.reply("resumed", "m3", at: start.addingTimeInterval(3_700), output: 1_000_000)
        let index = usage.index

        // Opus 5 output is $25 a million.
        let items = try await QuotaAttribution.items(index: index, accountIDs: ["a"], since: start)
        #expect(abs((items.first { $0.conversationID == "original" }?.cost ?? 0) - 50) < 1e-9)
        #expect(abs((items.first { $0.conversationID == "resumed" }?.cost ?? 0) - 25) < 1e-9)
        #expect(items.reduce(0) { $0 + $1.replies } == 3)
        #expect(abs((try await QuotaAttribution.models(index: index, since: start).first?.cost ?? 0) - 75) < 1e-9)
        #expect(try await QuotaAttribution.models(index: index, accountIDs: ["b"], since: start).isEmpty)

        let distinct = try await Projects.costs(index: index, distinct: true)
        #expect(abs(distinct.values.reduce(0, +) - 75) < 1e-9)
        #expect(abs((try await Projects.costs(index: index, distinct: false)["resumed"] ?? 0) - 75) < 1e-9)

        let month = try await MonthStats.build(index: index, month: start)
        #expect(month.replies == 3 && month.tokens == 3_000_000 && abs(month.cost - 75) < 1e-9)

        // The resumed conversation reads with every reply in its file.
        let record = try await FlightRecord.load(conversationID: "resumed", index: index)
        #expect(record.replies.count == 3 && abs(record.totalCost - 75) < 1e-9)
    }

    @Test("A cache break and a model change copied into a resumed conversation are counted once")
    func copiedBreaksCountOnce() async throws {
        let usage = try UsageIndex()
        let start = Self.start
        try await usage.conversation("original", account: "a", started: start)
        try await usage.conversation("resumed", account: "a", started: start.addingTimeInterval(7_200))
        for conversation in ["original", "resumed"] {
            try await usage.reply(conversation, "m1", at: start, read: 99_000, write1h: 1_000)
            try await usage.reply(conversation, "m2", at: start.addingTimeInterval(2 * 3_600), model: "claude-sonnet-5",
                                  write1h: 100_000)
        }
        let summary = try await CacheBreaks.summary(index: usage.index, since: start.addingTimeInterval(-60))
        #expect(summary.breaks == 1 && summary.tokens == 100_000)
        // Written at twice Sonnet 5's $2, less the tenth reading would have cost.
        #expect(abs(summary.extra - 0.38) < 1e-9)
        #expect(try await CacheBreaks.summary(index: usage.index, accountIDs: ["b"], since: start).breaks == 0)

        let drift = try await ModelDrift.unexplained(index: usage.index, since: start.addingTimeInterval(-60))
        #expect(drift.count == 1)
        #expect(try await ModelDrift.unexplained(index: usage.index, since: start.addingTimeInterval(-60),
                                                 until: start.addingTimeInterval(3_600)).isEmpty)

        // The reader marks the break at the same price.
        let record = try await FlightRecord.load(conversationID: "resumed", index: usage.index)
        let marker = TimelineMarkers.markers(record: record, switches: [], runs: []).first
        #expect(marker?.kind == .cacheBreak(gap: 2 * 3_600, cost: summary.extra))
    }

    @Test("A cache about to go cold is priced at the write it will need: an hour's, or five minutes'")
    func expiryByTTL() async throws {
        let usage = try UsageIndex()
        let start = Self.start
        try await usage.conversation("hour", account: "a", started: start)
        try await usage.reply("hour", "h1", at: start, write1h: 100_000)
        try await usage.reply("hour", "h2", at: start.addingTimeInterval(60), read: 100_000)
        try await usage.conversation("five", account: "a", started: start)
        try await usage.reply("five", "f1", at: start, write5m: 100_000)

        let hour = try #require(try await CacheBreaks.expiry(conversationID: "hour", index: usage.index))
        #expect(hour.hourLong && hour.at == start.addingTimeInterval(60 + 3_600))
        #expect(abs(hour.extra - 100_000 * 5 * (2 - 0.1) / 1_000_000) < 1e-9)
        let five = try #require(try await CacheBreaks.expiry(conversationID: "five", index: usage.index))
        #expect(!five.hourLong && five.at == start.addingTimeInterval(300))
        #expect(abs(five.extra - 100_000 * 5 * (1.25 - 0.1) / 1_000_000) < 1e-9)
    }

    @Test("Each model's cache reads are priced as its own, and other platforms' ids are recognised")
    func pricing() {
        func read(_ model: String) -> Double {
            Pricing.cost(model: model, input: 0, output: 0, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0)
        }
        #expect(abs(read("claude-fable-5") - 1) < 1e-9)
        #expect(abs(read("claude-mythos-5") - 1) < 1e-9)
        #expect(abs(read("claude-fable-5-1") - 0.25) < 1e-9)
        #expect(abs(read("claude-mythos-5-1") - 0.25) < 1e-9)

        #expect(Pricing.rate(for: "us.anthropic.claude-opus-4-1-20250805-v1:0").input == 15)
        #expect(Pricing.rate(for: "anthropic.claude-haiku-4-5-20251001-v1:0").input == 1)
        #expect(Pricing.rate(for: "claude-opus-4-5@20251101").input == 5)
        #expect(Pricing.baseID("global.anthropic.claude-sonnet-4-6") == "claude-sonnet-4-6")
        #expect(Pricing.knows("eu.anthropic.claude-sonnet-5-v1:0"))
        #expect(!Pricing.knows("claude-something-new"))
        #expect(Pricing.rate(for: "claude-something-new").input == 5)

        #expect(Pricing.contextWindow(for: "claude-haiku-4-5-20251001") == 200_000)
        #expect(Pricing.contextWindow(for: "claude-haiku-4-5", peak: 300_000) == 1_000_000)
        #expect(Pricing.contextWindow(for: "claude-sonnet-4-5[1m]") == 1_000_000)
        #expect(Pricing.contextWindow(for: "claude-opus-5-5") == 1_000_000)
    }

    @Test("Amounts read as the app shows them: nothing, a fraction of a cent, cents, whole dollars")
    func dollars() {
        let us = Locale(identifier: "en_US")
        #expect(Pricing.dollars(0, locale: us) == "$0")
        #expect(Pricing.dollars(0.004, locale: us) == "under 1¢")
        #expect(Pricing.dollars(0.5, locale: us) == "$0.50")
        #expect(Pricing.dollars(12.346, locale: us) == "$12.35")
        #expect(Pricing.dollars(1_234.4, locale: us) == "$1,234")
    }
}

@Suite("Limits")
struct LimitAccuracyTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Claude Code's weekly limits for one model are read, and the tightest drives room, alerts and forecast")
    func scopedLimits() throws {
        let fetched = Self.now.addingTimeInterval(-600)
        let reset = "2026-09-23T19:59:59.857548+00:00"
        let json = """
            {"cachedUsageUtilization": {"accountUuid": "acct", "fetchedAtMs": \(fetched.timeIntervalSince1970 * 1000),
              "utilization": {
                "five_hour": {"utilization": 8, "resets_at": null},
                "seven_day": {"utilization": 18, "resets_at": "2026-09-23T20:00:00.857337+00:00"},
                "seven_day_opus": null,
                "limits": [
                  {"kind": "session", "group": "session", "percent": 8, "resets_at": null, "scope": null, "is_active": false},
                  {"kind": "weekly_all", "group": "weekly", "percent": 18, "scope": null, "is_active": false},
                  {"kind": "weekly_scoped", "group": "weekly", "percent": 85, "resets_at": "\(reset)",
                   "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true},
                  {"kind": "weekly_scoped", "group": "weekly", "percent": 99, "resets_at": "\(reset)",
                   "scope": {"model": {"id": null, "display_name": "Mythos"}, "surface": null}, "is_active": false}
                ]}}}
            """
        let cached = try #require(QuotaReader.cached(from: try JSONValue.parse(Data(json.utf8))))
        #expect(cached.accountID == "acct")
        let scoped = cached.windows.filter { $0.kind == .weeklyScoped }
        #expect(scoped.count == 1)
        #expect(scoped.first?.scope == "Fable" && scoped.first?.percent == 85 && scoped.first?.title == "Weekly limit for Fable")
        #expect(scoped.first?.resetsAt == QuotaReader.parseDate(reset))

        // Read the day before that reset, so nothing rolls over.
        let readAt = try #require(QuotaReader.parseDate(reset)).addingTimeInterval(-86_400)
        let fresh = QuotaReader.Cached(accountID: "acct", fetchedAt: readAt, windows: cached.windows)
        let resolved = try #require(QuotaReader.resolve(cached: fresh, history: [], now: readAt))
        let quota = AccountQuota(account: ClaudeAccount(id: "acct", email: nil, label: "Work"), installIDs: [],
                                 asOf: resolved.asOf, windows: resolved.windows, history: [], forecast: nil)
        #expect(quota.tightestWeekly?.scope == "Fable")
        #expect(quota.headroom == 15)
        #expect(QuotaReader.weeklyForecast(quota.tightestWeekly, asOf: readAt, now: readAt) != nil)
        let alerts = LimitAlerts.due([quota], alreadySent: [], now: readAt)
        #expect(alerts.map(\.window) == [.weeklyScoped])
        #expect(alerts.first?.scope == "Fable" && alerts.first?.threshold == 80)
        #expect(alerts.first?.key.contains("weeklyScoped:Fable") == true)
    }

    static func samples(_ points: [(TimeInterval, Double, Double)]) -> [QuotaSample] {
        points.map { QuotaSample(date: Date(timeIntervalSince1970: $0.0), fiveHour: $0.1, weekly: $0.2) }
    }

    @Test("An estimated weekly reset that passes after the last reading starts the week over")
    func estimatedResetStartsOver() throws {
        let drop: TimeInterval = 1_000_800
        let history = Self.samples([(1_000_000, 10, 50), (1_003_000, 10, 3), (drop + 6 * 86_400, 30, 40)])
        let reset = try #require(QuotaReader.estimatedWeeklyReset(history))
        #expect(reset == Date(timeIntervalSince1970: drop + 7 * 86_400))

        // Before the reset, the reading stands.
        let before = try #require(QuotaReader.resolve(cached: nil, history: history,
                                                      now: Date(timeIntervalSince1970: drop + 6 * 86_400 + 3_600)))
        #expect(before.windows.first { $0.kind == .weekly }?.percent == 40)

        // An hour after it, with no newer reading, the week has started over.
        let after = try #require(QuotaReader.resolve(cached: nil, history: history,
                                                     now: Date(timeIntervalSince1970: drop + 7 * 86_400 + 3_600)))
        let weekly = try #require(after.windows.first { $0.kind == .weekly })
        #expect(weekly.percent == 0)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: drop + 14 * 86_400))
    }

    @Test("A five-hour reading with no reset time goes unknown after five hours, and leaves room alone")
    func staleFiveHour() throws {
        let history = Self.samples([(1_000_000, 90, 20)])
        let asOf = Date(timeIntervalSince1970: 1_000_000)
        let soon = try #require(QuotaReader.resolve(cached: nil, history: history, now: asOf.addingTimeInterval(3_600)))
        let fresh = try #require(soon.windows.first { $0.kind == .fiveHour })
        #expect(fresh.percent == 90 && !fresh.isStale)

        let later = try #require(QuotaReader.resolve(cached: nil, history: history, now: asOf.addingTimeInterval(6 * 3_600)))
        let stale = try #require(later.windows.first { $0.kind == .fiveHour })
        #expect(stale.isStale && stale.percent == 0)
        let quota = AccountQuota(account: ClaudeAccount(id: "a", email: nil), installIDs: [], asOf: asOf,
                                 windows: later.windows, history: history, forecast: nil)
        #expect(quota.headroom == 80)
    }

    @Test("A five-hour alert without a reset time is once per five hours of readings, not once ever")
    func fiveHourAlertPeriods() {
        func quota(_ asOf: Date) -> AccountQuota {
            AccountQuota(account: ClaudeAccount(id: "a", email: nil, label: "Work"), installIDs: [], asOf: asOf,
                         windows: [QuotaWindow(kind: .fiveHour, percent: 85, resetsAt: nil, resetIsEstimate: true)],
                         history: [], forecast: nil)
        }
        let bucket = (Self.now.timeIntervalSince1970 / 18_000).rounded(.down) * 18_000
        let first = Date(timeIntervalSince1970: bucket + 600)
        let sent = LimitAlerts.due([quota(first)], alreadySent: [], now: first)
        #expect(sent.count == 1 && sent[0].key.hasSuffix("|p\(Int(bucket / 18_000))"))
        let sameStretch = first.addingTimeInterval(3_600)
        #expect(LimitAlerts.due([quota(sameStretch)], alreadySent: Set(sent.map(\.key)), now: sameStretch).isEmpty)
        let nextStretch = first.addingTimeInterval(6 * 3_600)
        #expect(LimitAlerts.due([quota(nextStretch)], alreadySent: Set(sent.map(\.key)), now: nextStretch).count == 1)
    }
}
