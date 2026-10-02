import Foundation
import Testing
@testable import CoworkKit

@Suite("Insights")
struct InsightsTests {
    @Test("Nothing to say is no insight")
    func quiet() {
        #expect(Insights.secrets(open: 0) == nil)
        #expect(Insights.memory(unlinked: 0, pastCut: 0) == nil)
        #expect(Insights.drift([]) == nil)
        #expect(Insights.expiring(3, keeping: true) == nil)
        #expect(Insights.cacheBreaks(extra: 0.4, breaks: 2, hourLong: false) == nil)
        #expect(Insights.corrections([]) == nil)
    }

    @Test("The heaviest come first, at most three, and Not Now hides one until it changes")
    func ranking() throws {
        let all = [Insights.secrets(open: 2), Insights.memory(unlinked: 5, pastCut: 0), Insights.drift(["Migrate"]),
                   Insights.expiring(4, keeping: false), Insights.cacheBreaks(extra: 4.1, breaks: 7, hourLong: true)].compactMap { $0 }
        let now = Date()
        #expect(Insights.ranked(all, snoozed: [:], now: now).map(\.kind) == [.secrets, .expiring, .memory])

        let snoozed = [Insights.secrets(open: 2)!.key: now.addingTimeInterval(Insights.snooze)]
        #expect(Insights.ranked(all, snoozed: snoozed, now: now).first?.kind == .expiring)
        // A third key is a new finding: it shows again.
        let more = [Insights.secrets(open: 3)!] + all.dropFirst()
        #expect(Insights.ranked(more, snoozed: snoozed, now: now).first?.kind == .secrets)
        // A week later the snooze is over.
        #expect(Insights.ranked(all, snoozed: snoozed, now: now.addingTimeInterval(Insights.snooze + 1)).first?.kind == .secrets)
    }

    @Test("Last month's card in the first days of a month only")
    func month() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let insight = try #require(Insights.month(now: early, calendar: calendar))
        #expect(insight.title.contains("September"))
        #expect(Insights.month(now: late, calendar: calendar) == nil)
    }

    @Test("Corrections say where they came up, in one plain sentence")
    func correctionsSentence() throws {
        let examples = ["a", "b", "c"].map { CorrectionSuggestion.Example(text: "Use tabs", conversationID: $0, conversationTitle: "T", date: nil) }
        let everywhere = CorrectionSuggestion(project: nil, rule: "Use tabs", examples: examples, key: "tabs use")
        #expect(Insights.corrections([everywhere])?.detail == "“Use tabs” came up in 3 conversations across your projects.")
        let here = CorrectionSuggestion(project: "/repo/billing", rule: "Use tabs", examples: examples, key: "tabs use")
        #expect(Insights.corrections([here])?.detail == "“Use tabs” came up in 3 conversations in billing.")
        #expect(Insights.correctionsSubject([here, everywhere])?.project == "/repo/billing")
    }

    @Test("Words match the number")
    func plurals() {
        #expect(Insights.secrets(open: 1)?.title == "A key in your conversations to rotate")
        #expect(Insights.secrets(open: 2)?.title == "2 keys in your conversations to rotate")
        #expect(Insights.memory(unlinked: 1, pastCut: 0)?.title == "A memory note Claude never sees")
    }
}
