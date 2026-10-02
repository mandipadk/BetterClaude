import Foundation

/// A month with Claude, across every install and account: how much, when, with which models
/// and tools, on what. Every number comes from the index; nothing is estimated but cost.
public struct MonthStats: Sendable, Equatable {
    public let month: Date
    public let conversations: Int
    public let prompts: Int
    public let replies: Int
    /// Conversations with a prompt on each day of the month, first day first.
    public let days: [Int]
    public let longestStreak: Int
    /// Prompts in each hour of the day, 0 to 23.
    public let hours: [Int]
    public let tokens: Int64
    public let cost: Double
    /// Share of replies per model, largest first.
    public let models: [(name: String, replies: Int)]
    public let tools: [(name: String, uses: Int)]
    public let projects: [(name: String, conversations: Int)]
    public let places: [(name: String, conversations: Int)]
    public let filesChanged: Int
    public let pullRequests: Int
    public let compactions: Int

    public var activeDays: Int { days.filter { $0 > 0 }.count }
    public var busiestHour: Int? { hours.allSatisfy { $0 == 0 } ? nil : hours.indices.max { hours[$0] < hours[$1] } }
    public var busiestDay: (day: Int, conversations: Int)? {
        guard let index = days.indices.max(by: { days[$0] < days[$1] }), days[index] > 0 else { return nil }
        return (index + 1, days[index])
    }

    public static func == (a: MonthStats, b: MonthStats) -> Bool {
        a.month == b.month && a.conversations == b.conversations && a.prompts == b.prompts && a.days == b.days
            && a.hours == b.hours && a.tokens == b.tokens
    }

    public static func build(index: HistoryIndex, month: Date, calendar: Calendar = .current) async throws -> MonthStats {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let range: [SQLiteValue] = [.date(start), .date(end)]
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30

        var dayConversations = Array(repeating: Set<String>(), count: dayCount)
        var hours = Array(repeating: 0, count: 24)
        var prompts = 0
        var conversations = Set<String>()
        for row in try await index.rows("""
            SELECT conversation_id, timestamp FROM messages
            WHERE role = 'user' AND kind = 'message' AND timestamp >= ? AND timestamp < ?
            """, range) {
            guard let id = row.text(0), let time = row.date(1) else { continue }
            prompts += 1
            conversations.insert(id)
            let day = calendar.component(.day, from: time) - 1
            if dayConversations.indices.contains(day) { dayConversations[day].insert(id) }
            hours[calendar.component(.hour, from: time)] += 1
        }
        let days = dayConversations.map(\.count)
        var streak = 0, longest = 0
        for count in days { streak = count > 0 ? streak + 1 : 0; longest = max(longest, streak) }

        var replies = 0, tokens: Int64 = 0, cost = 0.0
        var models: [String: Int] = [:]
        for row in try await index.rows("""
            SELECT model, COUNT(*), SUM(input), SUM(output), SUM(cache_read), SUM(cache_write_5m), SUM(cache_write_1h)
            FROM \(DistinctUsage.table) WHERE timestamp >= ? AND timestamp < ? GROUP BY model
            """, range) {
            guard let model = row.text(0) else { continue }
            let count = Int(row.int(1))
            replies += count
            tokens += row.int(2) + row.int(3) + row.int(4) + row.int(5) + row.int(6)
            cost += Pricing.cost(model: model, input: row.int(2), output: row.int(3), cacheRead: row.int(4),
                                 cacheWrite5m: row.int(5), cacheWrite1h: row.int(6))
            models[Self.modelName(model), default: 0] += count
        }

        let tools = try await index.rows("""
            SELECT name, COUNT(*) FROM tool_calls WHERE timestamp >= ? AND timestamp < ?
            GROUP BY name ORDER BY COUNT(*) DESC LIMIT 6
            """, range).compactMap { row in row.text(0).map { (name: Self.toolName($0), uses: Int(row.int(1))) } }

        var projects: [String: Set<String>] = [:]
        var places: [String: Set<String>] = [:]
        if !conversations.isEmpty {
            let ids = Array(conversations)
            for row in try await index.rows("""
                SELECT id, project_path, kind, install_name FROM conversations
                WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, ids.map(SQLiteValue.text)) {
                guard let id = row.text(0) else { continue }
                if let path = row.text(1), path.hasPrefix("/") {
                    projects[URL(fileURLWithPath: Projects.root(of: path)).lastPathComponent, default: []].insert(id)
                }
                places[HistorySearch.place(kind: row.text(2), install: row.text(3)), default: []].insert(id)
            }
        }
        let files = try await index.rows("""
            SELECT COUNT(DISTINCT file_path) FROM tool_calls WHERE file_path IS NOT NULL
              AND name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') AND timestamp >= ? AND timestamp < ?
            """, range).first?.int(0) ?? 0
        let pulls = try await index.rows("SELECT COUNT(DISTINCT url) FROM pull_requests WHERE timestamp >= ? AND timestamp < ?",
                                         range).first?.int(0) ?? 0
        let compactions = try await index.rows("""
            SELECT COUNT(*) FROM messages WHERE kind = 'compaction' AND timestamp >= ? AND timestamp < ?
            """, range).first?.int(0) ?? 0

        return MonthStats(
            month: start, conversations: conversations.count, prompts: prompts, replies: replies, days: days,
            longestStreak: longest, hours: hours, tokens: tokens, cost: cost,
            models: models.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            tools: tools,
            projects: projects.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5).map { ($0.0, $0.1) },
            places: places.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.map { ($0.0, $0.1) },
            filesChanged: Int(files), pullRequests: Int(pulls), compactions: Int(compactions))
    }

    /// "Opus 5.5" for "claude-opus-5-5-20260101".
    public static func modelName(_ id: String) -> String {
        let parts = id.lowercased().replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// MCP tools read as the tool's own name.
    static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }
}
