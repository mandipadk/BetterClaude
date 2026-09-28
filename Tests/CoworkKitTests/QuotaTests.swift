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
