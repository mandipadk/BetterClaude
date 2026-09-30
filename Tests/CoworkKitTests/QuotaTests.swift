import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Quota")
struct QuotaTests {

    @Test("List prices weigh models against each other, and an unknown model isn't free")
    func pricing() {
        #expect(Pricing.cost(model: "claude-fable-5-1", input: 0, output: 1_000_000, cacheRead: 0,
                             cacheWrite5m: 0, cacheWrite1h: 0) == 50)
        #expect(abs(Pricing.cost(model: "claude-opus-5-5", input: 0, output: 0, cacheRead: 1_000_000,
                                 cacheWrite5m: 0, cacheWrite1h: 0) - 0.2) < 1e-9)
        #expect(Pricing.rate(for: "claude-opus-4-1-20250805").input == 15)
        #expect(Pricing.rate(for: "claude-opus-4-8[1m]").input == 5)
        #expect(Pricing.rate(for: "claude-sonnet-5").output == 10)
        #expect(Pricing.rate(for: "claude-something-new").input == 5)
        #expect(abs(Pricing.cost(model: "claude-sonnet-4-6", input: 0, output: 0, cacheRead: 0,
                                 cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000) - (3 * 1.25 + 3 * 2)) < 1e-9)
    }

    @Test("Each account's limits come from the freshest reading, with resets and a forecast")
    func readsTheSample() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, _ in
            let quotas = QuotaReader.accounts(in: snapshot, now: sample.now)
            let personal = try #require(quotas.first { $0.account.id == FixtureHome.personalAccount })
            let work = try #require(quotas.first { $0.account.id == FixtureHome.workAccount })

            // Claude Code's cache is newer than the Desktop samples, so it wins, resets and all.
            #expect(personal.window(.weekly)?.percent == 46)
            #expect(personal.window(.weekly)?.resetIsEstimate == false)
            #expect(personal.window(.weekly)?.resetsAt == sample.weekStart.addingTimeInterval(7 * 86_400))
            #expect(personal.window(.fiveHour)?.percent == 34)
            guard case .leftAtReset(let left)? = personal.forecast else {
                Issue.record("expected the personal week to end with room to spare")
                return
            }
            #expect(left > 25 && left < 45)

            // The work account has only Desktop samples: its reset is worked out from the drop.
            #expect(work.window(.weekly)?.percent ?? 0 >= 74)
            #expect(work.window(.weekly)?.resetIsEstimate == true)
            #expect(work.window(.weekly)?.resetsAt == sample.weekStart.addingTimeInterval(7 * 86_400))
            guard case .reachesLimit(let date)? = work.forecast else {
                Issue.record("expected the work week to run out before it resets")
                return
            }
            #expect(date < sample.weekStart.addingTimeInterval(7 * 86_400))
            #expect(work.history.count > 300)
        }
    }

    @Test("A week that reset after the last reading starts over; one read after the reset doesn't")
    func startsOverAfterAReset() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, _ in
            let later = sample.weekStart.addingTimeInterval(7 * 86_400 + 3_600)
            let personal = try #require(QuotaReader.accounts(in: snapshot, now: later)
                .first { $0.account.id == FixtureHome.personalAccount })
            #expect(personal.window(.weekly)?.percent == 0)
            #expect(personal.window(.weekly)?.resetsAt == sample.weekStart.addingTimeInterval(14 * 86_400))

            let history = [QuotaSample(date: Date(timeIntervalSince1970: 1_000_000), fiveHour: 0, weekly: 50),
                           QuotaSample(date: Date(timeIntervalSince1970: 1_003_000), fiveHour: 0, weekly: 3)]
            let reset = QuotaReader.estimatedWeeklyReset(history, now: Date(timeIntervalSince1970: 1_004_000))
            #expect(reset == Date(timeIntervalSince1970: 1_000_800 + 7 * 86_400))
        }
    }

    @Test("What used the week is told by conversation and by project, at list prices")
    func attributesUse() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let items = try await QuotaAttribution.items(index: index, accountIDs: [FixtureHome.personalAccount],
                                                         since: sample.now.addingTimeInterval(-30 * 86_400))
            #expect(!items.isEmpty)
            #expect(items == items.sorted { $0.cost > $1.cost })
            #expect(items.allSatisfy { $0.cost > 0 && $0.replies > 0 })
            let projects = QuotaAttribution.byProject(items)
            #expect(projects.contains { $0.name == "billing-service" })
            #expect(try await QuotaAttribution.items(index: index, accountIDs: [], since: .distantPast).isEmpty)
        }
    }
}

@Suite("Flight recorder and limit alerts")
struct FlightRecorderTests {

    @Test("A long session reads back reply by reply, with its compaction and costliest replies")
    func flightRecord() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Migrate the date picker to the new API" })
            let record = try await FlightRecord.load(conversationID: conversation.id, index: index)
            #expect(record.replies.count >= 72)
            #expect(record.compactions.count == 1)
            #expect(record.peakContext > 150_000 && record.window == 200_000)
            #expect(record.totalCost > 0)
            #expect(record.expensive.count == 3 && record.expensive[0].cost >= record.expensive[2].cost)
            #expect(record.replies.map(\.timestamp) == record.replies.map(\.timestamp).sorted())
        }
    }

    static func quota(_ id: String, fiveHour: Double, weekly: Double, asOf: Date, resets: Date?) -> AccountQuota {
        AccountQuota(account: ClaudeAccount(id: id, email: "\(id)@example.com", label: id.capitalized), installIDs: [],
                     asOf: asOf,
                     windows: [QuotaWindow(kind: .fiveHour, percent: fiveHour, resetsAt: resets, resetIsEstimate: false),
                               QuotaWindow(kind: .weekly, percent: weekly, resetsAt: resets.map { $0.addingTimeInterval(86_400 * 3) }, resetIsEstimate: false)],
                     history: [], forecast: nil)
    }

    @Test("An alert goes out once per threshold per window, only from a fresh reading, naming a roomier account")
    func limitAlerts() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = now.addingTimeInterval(3_600)
        let work = Self.quota("work", fiveHour: 86, weekly: 40, asOf: now.addingTimeInterval(-600), resets: reset)
        let personal = Self.quota("personal", fiveHour: 10, weekly: 30, asOf: now, resets: reset)
        let first = LimitAlerts.due([work, personal], alreadySent: [], now: now)
        #expect(first.count == 1)
        #expect(first[0].threshold == 80 && first[0].window == .fiveHour)
        #expect(first[0].alternative?.name == "Personal" && first[0].alternative?.left == 70)
        #expect(LimitAlerts.due([work, personal], alreadySent: Set(first.map(\.key)), now: now).isEmpty)

        // Past 95% is a new alert; after the reset the window is a new one.
        let worse = Self.quota("work", fiveHour: 96, weekly: 40, asOf: now, resets: reset)
        #expect(LimitAlerts.due([worse], alreadySent: Set(first.map(\.key)), now: now).first?.threshold == 95)
        let stale = Self.quota("work", fiveHour: 96, weekly: 40, asOf: now.addingTimeInterval(-3 * 3_600), resets: reset)
        #expect(LimitAlerts.due([stale], alreadySent: [], now: now).isEmpty)
        let over = Self.quota("work", fiveHour: 96, weekly: 40, asOf: now, resets: now.addingTimeInterval(-60))
        #expect(LimitAlerts.due([over], alreadySent: [], now: now).isEmpty)
    }
}

@Suite("Your month")
struct MonthStatsTests {
    @Test("A month counts conversations, prompts, days, hours, models and tools from the index")
    func month() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let stats = try await MonthStats.build(index: index, month: sample.now)
            #expect(stats.conversations > 5 && stats.prompts >= stats.conversations)
            #expect(stats.days.count >= 28 && stats.activeDays > 3)
            #expect(stats.hours.count == 24 && stats.hours.reduce(0, +) == stats.prompts)
            #expect(stats.longestStreak >= 1 && stats.longestStreak <= stats.activeDays)
            #expect(stats.models.first?.name == "Sonnet 5")
            #expect(stats.tools.contains { $0.name == "Edit" })
            #expect(stats.pullRequests == 1 && stats.compactions == 1 && stats.cost > 0)
        }
    }

    @Test("Model ids read as names")
    func names() {
        #expect(MonthStats.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(MonthStats.modelName("claude-sonnet-4-6-20260101") == "Sonnet 4.6")
        #expect(MonthStats.modelName("claude-fable-5-1") == "Fable 5.1")
        #expect(MonthStats.toolName("mcp__linear__create_issue") == "create_issue")
    }
}

@Suite("Context coach")
struct ContextCoachTests {
    @Test("A live session past 75% of its window gets one heads-up per stretch, and a quiet one gets none")
    func nudge() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let url = try #require(conversation.transcriptURL)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record = #"{"type":"assistant","isSidechain":true,"timestamp":"\#(formatter.string(from: sample.now.addingTimeInterval(-60)))","message":{"role":"assistant","model":"claude-opus-5","id":"msg_full","usage":{"input_tokens":5,"output_tokens":300,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000},"content":[]}}"#
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((record + "\n").utf8))
            try handle.close()
            try await index.update(from: snapshot)

            let live = [ContextCoach.Live(sessionID: "s1", conversationID: conversation.id, project: "billing-service")]
            let nudges = try await ContextCoach.due(live, index: index, alreadySent: [], now: sample.now)
            #expect(nudges.count == 1 && nudges[0].percent == 86 && nudges[0].key == "s1|75|0")
            #expect(try await ContextCoach.due(live, index: index, alreadySent: Set(nudges.map(\.key)), now: sample.now).isEmpty)
            // An hour later with nothing new, it's not running hot any more.
            #expect(try await ContextCoach.due(live, index: index, alreadySent: [], now: sample.now.addingTimeInterval(3_600)).isEmpty)
        }
    }
}
