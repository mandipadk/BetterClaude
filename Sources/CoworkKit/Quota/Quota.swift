import Foundation

/// How much of an account's plan limits is used, as Claude itself last reported it.
public struct AccountQuota: Sendable, Identifiable {
    public var id: String { account.id }
    public let account: ClaudeAccount
    /// Installs signed into this account.
    public let installIDs: [String]
    /// When the figures below were read by Claude.
    public let asOf: Date
    public let windows: [QuotaWindow]
    /// Readings over time, oldest first.
    public let history: [QuotaSample]
    public let forecast: QuotaForecast?

    public func window(_ kind: QuotaWindow.Kind) -> QuotaWindow? { windows.first { $0.kind == kind } }

    /// When the current week of the weekly limit began, if that's known.
    public var weekStart: Date? { window(.weekly)?.resetsAt.map { $0.addingTimeInterval(-7 * 86_400) } }
}

public struct QuotaWindow: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case fiveHour, weekly, weeklyOpus, weeklySonnet, weeklyCowork

        public var title: String {
            switch self {
            case .fiveHour: return "Five-hour limit"
            case .weekly: return "Weekly limit"
            case .weeklyOpus: return "Weekly limit for Opus"
            case .weeklySonnet: return "Weekly limit for Sonnet"
            case .weeklyCowork: return "Weekly limit for Cowork"
            }
        }
    }

    public let kind: Kind
    /// Percent of the limit used, 0 to 100.
    public let percent: Double
    public let resetsAt: Date?
    /// The reset time was worked out from when usage last dropped, not reported by Claude.
    public let resetIsEstimate: Bool
}

public struct QuotaSample: Sendable, Equatable {
    public let date: Date
    public let fiveHour: Double
    public let weekly: Double
}

public enum QuotaForecast: Sendable, Equatable {
    /// At the pace since the week began, the weekly limit is reached at this time.
    case reachesLimit(Date)
    /// At that pace, this much of the limit is left when it resets.
    case leftAtReset(percent: Double)
}

/// Reads the plan usage every Claude on the Mac keeps: Claude Code's cached limits, and the
/// usage history each Claude Desktop install records.
public enum QuotaReader {

    public static func accounts(in snapshot: CatalogSnapshot, now: Date = Date()) -> [AccountQuota] {
        var samples: [String: [QuotaSample]] = [:]
        var installs: [String: Set<String>] = [:]

        for install in snapshot.installs where install.isDesktop {
            let refs = snapshot.accounts[install.id] ?? []
            let fallback = snapshot.account(of: install)?.id
            for (org, found) in desktopHistory(at: install.dataRoot) {
                guard let account = refs.first(where: { $0.orgId == org })?.accountId ?? fallback else { continue }
                samples[account, default: []] += found
                installs[account, default: []].insert(install.id)
            }
        }

        let cached = claudeCodeCache(paths: snapshot.paths)
        if let cached, let cli = snapshot.installs.first(where: { $0.kind == .claudeCode }) {
            installs[cached.accountID, default: []].insert(cli.id)
        }

        var accountIDs = Set(samples.keys)
        if let cached { accountIDs.insert(cached.accountID) }
        let known = Dictionary(snapshot.knownAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        return accountIDs.compactMap { id -> AccountQuota? in
            let history = dedupe(samples[id] ?? [])
            let account = known[id] ?? (cached?.accountID == id ? snapshot.claudeCodeAccount : nil)
                ?? ClaudeAccount(id: id, email: nil)
            let fromCache = cached?.accountID == id ? cached : nil
            let latest = history.last
            var windows: [QuotaWindow]
            let asOf: Date
            if let fromCache, fromCache.fetchedAt >= (latest?.date ?? .distantPast) {
                windows = fromCache.windows
                asOf = fromCache.fetchedAt
            } else if let latest {
                asOf = latest.date
                let weeklyReset = fromCache?.windows.first { $0.kind == .weekly }?.resetsAt
                    ?? estimatedWeeklyReset(history, now: now)
                windows = [
                    QuotaWindow(kind: .fiveHour, percent: latest.fiveHour, resetsAt: nil, resetIsEstimate: true),
                    QuotaWindow(kind: .weekly, percent: latest.weekly, resetsAt: weeklyReset,
                                resetIsEstimate: fromCache == nil),
                ]
            } else {
                return nil
            }
            // A reset time that has passed moves on to the next one. If it passed after the
            // reading was taken, the window has started over since; if before, the reading
            // already belongs to the new window.
            windows = windows.map { window in
                guard let reset = window.resetsAt, reset <= now else { return window }
                if window.kind == .fiveHour {
                    return QuotaWindow(kind: .fiveHour, percent: reset > asOf ? 0 : window.percent,
                                       resetsAt: nil, resetIsEstimate: true)
                }
                var next = reset
                while next <= now { next.addTimeInterval(7 * 86_400) }
                let startedOver = next.addingTimeInterval(-7 * 86_400) > asOf
                return QuotaWindow(kind: window.kind, percent: startedOver ? 0 : window.percent, resetsAt: next,
                                   resetIsEstimate: window.resetIsEstimate)
            }
            let forecast = weeklyForecast(windows.first { $0.kind == .weekly }, asOf: asOf, now: now)
            return AccountQuota(account: account, installIDs: (installs[id] ?? []).sorted(), asOf: asOf,
                                windows: windows, history: history, forecast: forecast)
        }
        .sorted { ($0.window(.weekly)?.percent ?? 0) > ($1.window(.weekly)?.percent ?? 0) }
    }

    // MARK: Sources

    /// `plan-usage-history.json` in a Desktop data folder: samples by organisation.
    static func desktopHistory(at dataRoot: URL) -> [String: [QuotaSample]] {
        let url = dataRoot.appendingPathComponent("plan-usage-history.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONValue.parse(data) else { return [:] }
        var out: [String: [QuotaSample]] = [:]
        for sample in value["samples"]?.arrayValue ?? [] {
            guard let millis = sample["t"]?.doubleValue, let usage = sample["u"] else { continue }
            let org = sample["org"]?.stringValue ?? ""
            out[org, default: []].append(QuotaSample(
                date: Date(timeIntervalSince1970: millis / 1000),
                fiveHour: usage["fh"]?.doubleValue ?? 0, weekly: usage["sd"]?.doubleValue ?? 0))
        }
        return out
    }

    struct Cached {
        let accountID: String
        let fetchedAt: Date
        let windows: [QuotaWindow]
    }

    /// The limits Claude Code last fetched for the account it's signed into, from its state file.
    static func claudeCodeCache(paths: HostPaths) -> Cached? {
        let config = paths.claudeCodeConfigDir
        let state = config.standardizedFileURL == paths.home.appendingPathComponent(".claude").standardizedFileURL
            ? paths.home.appendingPathComponent(".claude.json")
            : config.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: state), let value = try? JSONValue.parse(data),
              let cache = value["cachedUsageUtilization"], let account = cache["accountUuid"]?.stringValue,
              let fetched = cache["fetchedAtMs"]?.doubleValue, let utilization = cache["utilization"] else { return nil }
        let keys: [(String, QuotaWindow.Kind)] = [
            ("five_hour", .fiveHour), ("seven_day", .weekly), ("seven_day_opus", .weeklyOpus),
            ("seven_day_sonnet", .weeklySonnet), ("seven_day_cowork", .weeklyCowork),
        ]
        let windows = keys.compactMap { key, kind -> QuotaWindow? in
            guard let entry = utilization[key], let percent = entry["utilization"]?.doubleValue else { return nil }
            return QuotaWindow(kind: kind, percent: percent,
                               resetsAt: entry["resets_at"]?.stringValue.flatMap(parseDate), resetIsEstimate: false)
        }
        guard !windows.isEmpty else { return nil }
        return Cached(accountID: account, fetchedAt: Date(timeIntervalSince1970: fetched / 1000), windows: windows)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Working things out

    static func dedupe(_ samples: [QuotaSample]) -> [QuotaSample] {
        var seen = Set<Int>()
        return samples.sorted { $0.date < $1.date }.filter { seen.insert(Int($0.date.timeIntervalSince1970 / 60)).inserted }
    }

    /// The weekly limit resets at the same time each week, so the last big drop in the
    /// history, carried forward a week at a time, says when it resets next.
    static func estimatedWeeklyReset(_ history: [QuotaSample], now: Date) -> Date? {
        var lastDrop: Date?
        let calendar = Calendar(identifier: .gregorian)
        // Within a week the figure only rises, so any fall is a reset. It happened between
        // the two readings, and resets fall on the hour.
        for (previous, sample) in zip(history, history.dropFirst()) where sample.weekly < previous.weekly {
            let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
            lastDrop = max(hour, previous.date)
        }
        guard var next = lastDrop else { return nil }
        while next <= now { next.addTimeInterval(7 * 86_400) }
        return next
    }

    /// Where the weekly limit is heading, at the average pace since the week began.
    static func weeklyForecast(_ weekly: QuotaWindow?, asOf: Date, now: Date) -> QuotaForecast? {
        guard let weekly, let reset = weekly.resetsAt, weekly.percent > 0 else { return nil }
        let weekStart = reset.addingTimeInterval(-7 * 86_400)
        let elapsed = asOf.timeIntervalSince(weekStart)
        guard elapsed > 6 * 3_600 else { return nil }
        let perSecond = weekly.percent / elapsed
        let untilFull = (100 - weekly.percent) / perSecond
        let full = asOf.addingTimeInterval(untilFull)
        if full < reset { return .reachesLimit(max(full, now)) }
        let atReset = weekly.percent + perSecond * reset.timeIntervalSince(asOf)
        return .leftAtReset(percent: max(0, 100 - atReset))
    }
}

/// What used an account's limits: tokens from the history index, weighed at list prices.
public enum QuotaAttribution {

    public struct Item: Sendable, Identifiable, Equatable {
        public var id: String { conversationID }
        public let conversationID: String
        public let title: String
        public let projectPath: String?
        public let place: String
        /// At list price, in dollars; only meaningful next to the others.
        public let cost: Double
        public let outputTokens: Int64
        public let replies: Int
    }

    /// Every conversation that used tokens since `since`, heaviest first.
    public static func items(index: HistoryIndex, accountIDs: Set<String>, since: Date) async throws -> [Item] {
        guard !accountIDs.isEmpty else { return [] }
        let rows = try await index.rows("""
            SELECT c.id, c.title, c.project_path, c.kind, c.install_name, u.model,
                   SUM(u.input), SUM(u.output), SUM(u.cache_read), SUM(u.cache_write_5m), SUM(u.cache_write_1h),
                   COUNT(*)
            FROM usage u JOIN conversations c ON c.id = u.conversation_id
            WHERE u.timestamp >= ? AND c.account_id IN (\(accountIDs.map { _ in "?" }.joined(separator: ",")))
            GROUP BY c.id, u.model
            """, [.date(since)] + accountIDs.sorted().map(SQLiteValue.text))
        var byConversation: [String: Item] = [:]
        for row in rows {
            let id = row.text(0) ?? ""
            let cost = Pricing.cost(model: row.text(5) ?? "", input: row.int(6), output: row.int(7),
                                    cacheRead: row.int(8), cacheWrite5m: row.int(9), cacheWrite1h: row.int(10))
            let previous = byConversation[id]
            byConversation[id] = Item(conversationID: id, title: row.text(1) ?? "Untitled", projectPath: row.text(2),
                                      place: HistorySearch.place(kind: row.text(3), install: row.text(4)),
                                      cost: (previous?.cost ?? 0) + cost,
                                      outputTokens: (previous?.outputTokens ?? 0) + row.int(7),
                                      replies: (previous?.replies ?? 0) + Int(row.int(11)))
        }
        return byConversation.values.sorted { $0.cost > $1.cost }
    }

    /// The same, added up by project folder; conversations outside one are grouped by place.
    public static func byProject(_ items: [Item]) -> [(name: String, cost: Double, conversations: Int)] {
        var totals: [String: (Double, Int)] = [:]
        for item in items {
            let name = item.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.place.prefix(1).uppercased() + item.place.dropFirst()
            let current = totals[name] ?? (0, 0)
            totals[name] = (current.0 + item.cost, current.1 + 1)
        }
        return totals.map { (name: $0.key, cost: $0.value.0, conversations: $0.value.1) }.sorted { $0.cost > $1.cost }
    }
}
