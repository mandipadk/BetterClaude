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
    /// The busiest projects, by folder; a worktree counts toward its repository.
    public let projects: [(name: String, conversations: Int)]
    /// Every project with a conversation in the month, not only the busiest.
    public let projectCount: Int
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
        // A prompt copied into a resumed conversation counts where it was first typed.
        for row in try await index.rows("""
            SELECT * FROM \(DistinctRows.messages("m.conversation_id, m.timestamp",
                where: "m.role = 'user' AND m.kind = 'message' AND m.timestamp >= ? AND m.timestamp < ?"))
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

        // MCP tools from different servers can share a name, and read as one.
        var toolUses: [String: Int] = [:]
        for row in try await index.rows("""
            SELECT name, COUNT(*) FROM \(DistinctRows.toolCalls("t.name", where: "t.timestamp >= ? AND t.timestamp < ?"))
            GROUP BY name
            """, range) {
            guard let name = row.text(0) else { continue }
            toolUses[Self.toolName(name), default: 0] += Int(row.int(1))
        }
        let tools = toolUses.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(6).map { (name: $0.key, uses: $0.value) }

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
                    projects[Projects.root(of: path), default: []].insert(id)
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
            SELECT COUNT(*) FROM \(DistinctRows.messages("m.id", where: "m.kind = 'compaction' AND m.timestamp >= ? AND m.timestamp < ?"))
            """, range).first?.int(0) ?? 0
        let projectNames = Projects.names(for: projects.keys)
        let busiestProjects: [(name: String, conversations: Int)] = projects
            .map { (name: projectNames[$0.key] ?? $0.key, conversations: $0.value.count) }
            .sorted { $0.conversations == $1.conversations ? $0.name < $1.name : $0.conversations > $1.conversations }

        return MonthStats(
            month: start, conversations: conversations.count, prompts: prompts, replies: replies, days: days,
            longestStreak: longest, hours: hours, tokens: tokens, cost: cost,
            models: models.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            tools: tools,
            projects: Array(busiestProjects.prefix(5)),
            projectCount: projects.count,
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
