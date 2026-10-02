import Foundation

/// Something one of Better Claude's features found that's worth a look: one sentence, one
/// number, one thing to do. Home shows the few that matter most, so features introduce
/// themselves when they have something to say rather than waiting to be found.
public struct Insight: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case secrets, corrections, memory, drift, expiring, cacheBreaks, month
    }

    public let kind: Kind
    /// Stable for the same finding, and different once it changes (a new key, a bigger
    /// number), so "Not Now" hides this one without hiding the next.
    public let key: String
    public var id: String { key }
    public let title: String
    public let detail: String
    /// The button: says exactly what it opens.
    public let action: String
    /// Higher comes first.
    public let weight: Int

    public init(kind: Kind, key: String, title: String, detail: String, action: String, weight: Int) {
        self.kind = kind
        self.key = key
        self.title = title
        self.detail = detail
        self.action = action
        self.weight = weight
    }
}

public enum Insights {

    /// How long "Not Now" keeps one out of sight.
    public static let snooze: TimeInterval = 7 * 86_400

    /// The ones to show: not snoozed, heaviest first, at most `limit`.
    public static func ranked(_ insights: [Insight], snoozed: [String: Date], now: Date = Date(),
                              limit: Int = 3) -> [Insight] {
        insights
            .filter { insight in
                guard let until = snoozed[insight.key] else { return true }
                return until <= now
            }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.kind.rawValue < $1.kind.rawValue }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Each feature's sentence

    public static func secrets(open: Int) -> Insight? {
        guard open > 0 else { return nil }
        return Insight(kind: .secrets, key: "secrets:\(open)",
                       title: open == 1 ? "A key in your conversations to rotate" : "\(open) keys in your conversations to rotate",
                       detail: "Pasted into a conversation, so anything that reads it can use it. Rotating one takes a minute.",
                       action: "Review", weight: 100)
    }

    public static func corrections(_ suggestions: [CorrectionSuggestion]) -> Insight? {
        guard let first = suggestions.max(by: { $0.conversations < $1.conversations }) else { return nil }
        let count = suggestions.count
        let place = first.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "several projects"
        return Insight(kind: .corrections, key: "corrections:\(suggestions.map(\.id).sorted().joined(separator: ","))",
                       title: count == 1 ? "Something you keep telling Claude" : "\(count) things you keep telling Claude",
                       detail: "“\(first.rule)” came up in \(first.conversations) \(place) conversations.",
                       action: "Add to CLAUDE.md", weight: 70)
    }

    public static func memory(unlinked: Int, pastCut: Int) -> Insight? {
        guard unlinked > 0 || pastCut > 0 else { return nil }
        let title: String
        if unlinked > 0 {
            title = unlinked == 1 ? "A memory note Claude never sees" : "\(unlinked) memory notes Claude never sees"
        } else {
            title = "\(pastCut) lines of memory never load"
        }
        return Insight(kind: .memory, key: "memory:\(unlinked):\(pastCut)", title: title,
                       detail: unlinked > 0 ? "Nothing in MEMORY.md links to them, so Claude doesn't find them."
                                            : "Claude only reads the first 200 lines of MEMORY.md.",
                       action: "Show Memory", weight: 60)
    }

    public static func drift(_ titles: [String]) -> Insight? {
        guard let first = titles.first else { return nil }
        return Insight(kind: .drift, key: "drift:\(titles.count):\(first)",
                       title: titles.count == 1 ? "A model changed on its own" : "\(titles.count) models changed on their own",
                       detail: "“\(first)” switched model partway through, with nothing on record asking for it.",
                       action: "See Where", weight: 50)
    }

    public static func expiring(_ count: Int, keeping: Bool) -> Insight? {
        guard count > 0, !keeping else { return nil }
        return Insight(kind: .expiring, key: "expiring:\(count)",
                       title: count == 1 ? "A conversation Claude Code deletes this week" : "\(count) conversations Claude Code deletes this week",
                       detail: "Keeping them automatically saves a copy before they go.",
                       action: "Show Kept", weight: 80)
    }

    /// Breaks over the last seven days; `hourLong` when sessions mostly keep the cache for an hour.
    public static func cacheBreaks(extra: Double, breaks: Int, hourLong: Bool) -> Insight? {
        guard breaks > 0, extra >= 1 else { return nil }
        let money = extra.formatted(.currency(code: "USD").precision(.fractionLength(extra < 10 ? 2 : 0)))
        return Insight(kind: .cacheBreaks, key: "breaks:\(Int(extra))",
                       title: "Breaks cost \(money) over the last seven days",
                       detail: "Coming back to a long conversation after \(hourLong ? "an hour" : "five minutes") rewrites its cache at list prices.",
                       action: "See Where", weight: 40)
    }

    /// In the first days of a month, last month's card.
    public static func month(now: Date = Date(), calendar: Calendar = .current) -> Insight? {
        let day = calendar.component(.day, from: now)
        guard day <= 5, let last = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        let name = last.formatted(.dateTime.month(.wide))
        let year = calendar.component(.year, from: last)
        return Insight(kind: .month, key: "month:\(year)-\(calendar.component(.month, from: last))",
                       title: "Your \(name) with Claude",
                       detail: "Every Claude on this Mac over the month, on one card you can save.",
                       action: "Open the Card", weight: 30)
    }
}
