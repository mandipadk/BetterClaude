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

    /// The plan's weekly limit and any weekly limit for one model or product, plan's first.
    public var weeklyWindows: [QuotaWindow] { windows.filter { $0.kind != .fiveHour } }

    /// The weekly limit closest to full: the one that stops you first.
    public var tightestWeekly: QuotaWindow? { weeklyWindows.max { $0.percent < $1.percent } }

    /// When the current week of the weekly limit began, if that's known.
    public var weekStart: Date? {
        (window(.weekly) ?? tightestWeekly)?.resetsAt.map { $0.addingTimeInterval(-7 * 86_400) }
    }

    /// How much of the tightest limit is left, 0 to 100. A five-hour reading too old to
    /// say anything doesn't count.
    public var headroom: Double? {
        let five = window(.fiveHour).flatMap { $0.isStale ? nil : $0.percent }
        let used = [five, tightestWeekly?.percent].compactMap { $0 }.max()
        return used.map { max(0, 100 - $0) }
    }
}

public struct QuotaWindow: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case fiveHour, weekly, weeklyOpus, weeklySonnet, weeklyCowork, weeklyScoped

        public var title: String {
            switch self {
            case .fiveHour: return "Five-hour limit"
            case .weekly: return "Weekly limit"
            case .weeklyOpus: return "Weekly limit for Opus"
            case .weeklySonnet: return "Weekly limit for Sonnet"
            case .weeklyCowork: return "Weekly limit for Cowork"
            case .weeklyScoped: return "Weekly limit for one model"
            }
        }

        /// What the limit covers, when it's narrower than the whole plan.
        var scope: String? {
            switch self {
            case .weeklyOpus: return "Opus"
            case .weeklySonnet: return "Sonnet"
            case .weeklyCowork: return "Cowork"
            default: return nil
            }
        }
    }

    public let kind: Kind
    /// Percent of the limit used, 0 to 100.
    public let percent: Double
    public let resetsAt: Date?
    /// The reset time was worked out from when usage last dropped, not reported by Claude.
    public let resetIsEstimate: Bool
    /// What a weekly limit for part of the plan covers, like "Fable".
    public let scope: String?
    /// A five-hour reading so old the window has certainly moved on, with nothing newer to say
    /// where it is now.
    public let isStale: Bool

    public init(kind: Kind, percent: Double, resetsAt: Date?, resetIsEstimate: Bool, scope: String? = nil,
                isStale: Bool = false) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.resetIsEstimate = resetIsEstimate
        self.scope = scope ?? kind.scope
        self.isStale = isStale
    }

    public var title: String { kind == .weeklyScoped ? scope.map { "Weekly limit for \($0)" } ?? kind.title : kind.title }

    func with(percent: Double, resetsAt: Date?, isStale: Bool = false) -> QuotaWindow {
        QuotaWindow(kind: kind, percent: percent, resetsAt: resetsAt, resetIsEstimate: resetIsEstimate, scope: scope,
                    isStale: isStale)
    }
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
        let known = snapshot.namedAccounts

        return accountIDs.compactMap { id -> AccountQuota? in
            let history = dedupe(samples[id] ?? [])
            let account = known[id] ?? (cached?.accountID == id ? snapshot.claudeCodeAccount : nil)
                ?? ClaudeAccount(id: id, email: nil)
            guard let resolved = resolve(cached: cached?.accountID == id ? cached : nil, history: history,
                                         now: now) else { return nil }
            let tightest = resolved.windows.filter { $0.kind != .fiveHour }.max { $0.percent < $1.percent }
            return AccountQuota(account: account, installIDs: (installs[id] ?? []).sorted(), asOf: resolved.asOf,
                                windows: resolved.windows, history: history,
                                forecast: weeklyForecast(tightest, asOf: resolved.asOf, now: now))
        }
        .sorted { ($0.tightestWeekly?.percent ?? 0) > ($1.tightestWeekly?.percent ?? 0) }
    }

    /// An account's limits as of now, from whichever reading is freshest.
    static func resolve(cached: Cached?, history: [QuotaSample], now: Date) -> (asOf: Date, windows: [QuotaWindow])? {
        let latest = history.last
        var windows: [QuotaWindow]
        let asOf: Date
        if let cached, cached.fetchedAt >= (latest?.date ?? .distantPast) {
            windows = cached.windows
            asOf = cached.fetchedAt
        } else if let latest {
            asOf = latest.date
            let weeklyReset = cached?.windows.first { $0.kind == .weekly }?.resetsAt ?? estimatedWeeklyReset(history)
            windows = [
                QuotaWindow(kind: .fiveHour, percent: latest.fiveHour, resetsAt: nil, resetIsEstimate: true),
                QuotaWindow(kind: .weekly, percent: latest.weekly, resetsAt: weeklyReset, resetIsEstimate: cached == nil),
            ]
        } else {
            return nil
        }
        // A reset time that has passed moves on to the next one. If it passed after the
        // reading was taken, the window has started over since; if before, the reading
        // already belongs to the new window.
        windows = windows.map { window in
            guard let reset = window.resetsAt, reset <= now else { return window }
            if window.kind == .fiveHour { return window.with(percent: reset > asOf ? 0 : window.percent, resetsAt: nil) }
            var next = reset
            while next <= now { next.addTimeInterval(7 * 86_400) }
            let startedOver = next.addingTimeInterval(-7 * 86_400) > asOf
            return window.with(percent: startedOver ? 0 : window.percent, resetsAt: next)
        }
        // Without a reset time, a five-hour reading older than five hours says nothing about now.
        windows = windows.map { window in
            guard window.kind == .fiveHour, window.resetsAt == nil, now.timeIntervalSince(asOf) > 5 * 3_600 else { return window }
            return window.with(percent: 0, resetsAt: nil, isStale: true)
        }
        return (asOf, windows)
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
        guard let data = try? Data(contentsOf: state), let value = try? JSONValue.parse(data) else { return nil }
        return cached(from: value)
    }

    /// `cachedUsageUtilization` in Claude Code's state: the plan's windows by key, and a list
    /// of limits that also holds weekly ones for a single model.
    static func cached(from value: JSONValue) -> Cached? {
        guard let cache = value["cachedUsageUtilization"], let account = cache["accountUuid"]?.stringValue,
              let fetched = cache["fetchedAtMs"]?.doubleValue, let utilization = cache["utilization"] else { return nil }
        let keys: [(String, QuotaWindow.Kind)] = [
            ("five_hour", .fiveHour), ("seven_day", .weekly), ("seven_day_opus", .weeklyOpus),
            ("seven_day_sonnet", .weeklySonnet), ("seven_day_cowork", .weeklyCowork),
        ]
        var windows = keys.compactMap { key, kind -> QuotaWindow? in
            guard let entry = utilization[key], let percent = entry["utilization"]?.doubleValue else { return nil }
            return QuotaWindow(kind: kind, percent: percent,
                               resetsAt: entry["resets_at"]?.stringValue.flatMap(parseDate), resetIsEstimate: false)
        }
        for limit in utilization["limits"]?.arrayValue ?? cache["limits"]?.arrayValue ?? [] {
            guard limit["kind"]?.stringValue == "weekly_scoped", limit["is_active"]?.boolValue != false,
                  let percent = limit["percent"]?.doubleValue ?? limit["utilization"]?.doubleValue,
                  let scope = scopeName(limit["scope"]),
                  !windows.contains(where: { $0.scope?.lowercased() == scope.lowercased() }) else { continue }
            windows.append(QuotaWindow(kind: .weeklyScoped, percent: percent,
                                       resetsAt: limit["resets_at"]?.stringValue.flatMap(parseDate),
                                       resetIsEstimate: false, scope: scope))
        }
        guard !windows.isEmpty else { return nil }
        return Cached(accountID: account, fetchedAt: Date(timeIntervalSince1970: fetched / 1000), windows: windows)
    }

    /// "Fable" for a limit scoped to a model, or the product's name for one scoped to a surface.
    static func scopeName(_ scope: JSONValue?) -> String? {
        guard let scope else { return nil }
        for key in ["model", "surface"] {
            guard let part = scope[key] else { continue }
            if let name = part["display_name"]?.stringValue ?? part.stringValue, !name.isEmpty { return name }
            if let id = part["id"]?.stringValue, !id.isEmpty { return MonthStats.modelName(id) }
        }
        return nil
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
    /// history, carried forward a week at a time, says when it resets next after the last
    /// reading. Whether that has passed by now is for the caller, which also knows to start
    /// the week over if it has.
    static func estimatedWeeklyReset(_ history: [QuotaSample]) -> Date? {
        var lastDrop: Date?
        let calendar = Calendar(identifier: .gregorian)
        // Within a week the figure only rises, so any fall is a reset. It happened between
        // the two readings, and resets fall on the hour.
        for (previous, sample) in zip(history, history.dropFirst()) where sample.weekly < previous.weekly {
            let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
            lastDrop = max(hour, previous.date)
        }
        guard var next = lastDrop, let last = history.last?.date else { return nil }
        while next <= last { next.addTimeInterval(7 * 86_400) }
        return next
    }

    /// Where a weekly limit is heading, at the average pace since the week began.
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

/// Claude Code copies a session's earlier replies into the file of a session resumed or
/// forked from it, under the same message id, so one reply can be in several conversations.
/// Totals across conversations read this in place of `usage`: each reply once, in the
/// conversation it first appeared in. The index marks the copies as it goes; see
/// ``HistoryIndex/copyMarking``.
enum DistinctUsage {
    /// Each reply once.
    static let table = "(SELECT * FROM usage WHERE is_copy = 0)"

    /// `AND c.account_id IN (…)` for a query joined to conversations as `c`, and its values.
    static func accounts(_ ids: Set<String>?) -> (sql: String, values: [SQLiteValue]) {
        guard let ids else { return ("", []) }
        return (" AND c.account_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", ids.sorted().map(SQLiteValue.text))
    }
}

/// Claude Code copies a session's earlier messages and tool calls into the file of a session
/// resumed from it too, under the same uuid or tool use id and with the same times. These
/// count each once, where it first appeared, the way ``DistinctUsage`` counts replies.
enum DistinctRows {
    /// `columns` of `messages m`, for the rows `filter` picks, each message once. The filter
    /// can use the conversation, joined as `c`.
    static func messages(_ columns: String, where filter: String) -> String {
        """
        (SELECT \(columns) FROM messages m JOIN (
            SELECT m.id AS rid, ROW_NUMBER() OVER (PARTITION BY COALESCE(m.uuid, 'row:' || m.id) ORDER BY
                m.timestamp IS NULL, m.timestamp, c.first_activity IS NULL, c.first_activity, m.id) AS appearance
            FROM messages m LEFT JOIN conversations c ON c.id = m.conversation_id WHERE \(filter)
        ) ranked ON ranked.rid = m.id WHERE ranked.appearance = 1)
        """
    }

    /// `columns` of `tool_calls t`, for the rows `filter` picks, each call once. The filter
    /// can use the conversation, joined as `c`.
    static func toolCalls(_ columns: String, where filter: String) -> String {
        """
        (SELECT \(columns) FROM tool_calls t JOIN (
            SELECT t.rowid AS rid, ROW_NUMBER() OVER (PARTITION BY COALESCE(t.tool_use_id, 'row:' || t.rowid) ORDER BY
                t.timestamp IS NULL, t.timestamp, c.first_activity IS NULL, c.first_activity, t.rowid) AS appearance
            FROM tool_calls t LEFT JOIN conversations c ON c.id = t.conversation_id WHERE \(filter)
        ) ranked ON ranked.rid = t.rowid WHERE ranked.appearance = 1)
        """
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

    /// Every conversation that used tokens since `since`, heaviest first. A reply copied into
    /// a resumed conversation counts only where it first appeared.
    public static func items(index: HistoryIndex, accountIDs: Set<String>, since: Date,
                             until: Date = .distantFuture) async throws -> [Item] {
        guard !accountIDs.isEmpty else { return [] }
        let accounts = DistinctUsage.accounts(accountIDs)
        let rows = try await index.rows("""
            SELECT c.id, c.title, c.project_path, c.kind, c.install_name, u.model,
                   SUM(u.input), SUM(u.output), SUM(u.cache_read), SUM(u.cache_write_5m), SUM(u.cache_write_1h),
                   COUNT(*)
            FROM \(DistinctUsage.table) u JOIN conversations c ON c.id = u.conversation_id
            WHERE u.timestamp >= ? AND u.timestamp < ?\(accounts.sql)
            GROUP BY c.id, u.model
            """, [.date(since), .date(until)] + accounts.values)
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

    /// What each model's replies came to over a stretch, at list prices, largest first; only
    /// these accounts' conversations, when given.
    public static func models(index: HistoryIndex, accountIDs: Set<String>? = nil, since: Date,
                              until: Date = .distantFuture) async throws -> [(name: String, cost: Double)] {
        if accountIDs?.isEmpty == true { return [] }
        let accounts = DistinctUsage.accounts(accountIDs)
        let rows = try await index.rows("""
            SELECT u.model, SUM(u.input), SUM(u.output), SUM(u.cache_read), SUM(u.cache_write_5m), SUM(u.cache_write_1h)
            FROM \(DistinctUsage.table) u LEFT JOIN conversations c ON c.id = u.conversation_id
            WHERE u.timestamp >= ? AND u.timestamp < ?\(accounts.sql) GROUP BY u.model
            """, [.date(since), .date(until)] + accounts.values)
        var byName: [String: Double] = [:]
        for row in rows {
            let model = row.text(0) ?? ""
            guard !model.isEmpty, !model.hasPrefix("<") else { continue }
            let cost = Pricing.cost(model: model, input: row.int(1), output: row.int(2),
                                    cacheRead: row.int(3), cacheWrite5m: row.int(4), cacheWrite1h: row.int(5))
            byName[model, default: 0] += cost
        }
        return byName.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// The same, added up by project folder (a worktree counts toward its repository);
    /// conversations outside one are grouped by place.
    public static func byProject(_ items: [Item]) -> [(name: String, cost: Double, conversations: Int)] {
        var totals: [String: (Double, Int)] = [:]
        var places: Set<String> = []
        for item in items {
            let key: String
            if let path = item.projectPath, !path.isEmpty {
                key = Projects.root(of: path)
            } else {
                key = item.place.prefix(1).uppercased() + item.place.dropFirst()
                places.insert(key)
            }
            let current = totals[key] ?? (0, 0)
            totals[key] = (current.0 + item.cost, current.1 + 1)
        }
        let names = Projects.names(for: totals.keys.filter { !places.contains($0) })
        return totals.map { (name: names[$0.key] ?? $0.key, cost: $0.value.0, conversations: $0.value.1) }
            .sorted { $0.cost > $1.cost }
    }
}
