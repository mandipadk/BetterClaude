import Foundation

/// Everything about one project folder, from every Claude and every account: people think in
/// projects, while Claude files things by app and account.
public struct ProjectSummary: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public let conversations: Int
    /// Where its conversations happened, busiest first.
    public let places: [String]
    public let accounts: Int
    public let firstActivity: Date?
    public let lastActivity: Date?
    /// Every reply's tokens at list prices.
    public let cost: Double
    public let filesChanged: Int
    public let pullRequests: Int
}

public struct ProjectDetail: Sendable {
    public struct Conversation: Sendable, Identifiable, Equatable {
        public let id: String
        public let sessionID: String?
        public let title: String
        public let place: String
        public let lastActivity: Date?
        public let cost: Double
        public let branch: String?
    }

    public struct PullRequest: Sendable, Identifiable, Equatable {
        public var id: String { url }
        public let url: String
        public let name: String
        public let conversationTitle: String
    }

    public struct File: Sendable, Identifiable, Equatable {
        public var id: String { path }
        public let path: String
        public let conversations: Int
        public let lastChanged: Date?
    }

    public let summary: ProjectSummary
    public let conversations: [Conversation]
    public let pullRequests: [PullRequest]
    public let files: [File]
    /// Conversations active each day, the last `days` days, oldest first.
    public let activity: [(day: Date, conversations: Int)]
    /// CLAUDE.md files and Claude Code's memory for the project.
    public let memory: [URL]
}

public enum Projects {

    /// A worktree Claude made for a session belongs to the repository it came from.
    public static func root(of path: String) -> String {
        for marker in ["/.claude/worktrees/", "/.worktrees/"] {
            if let range = path.range(of: marker) { return String(path[..<range.lowerBound]) }
        }
        return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }

    static func costs(index: HistoryIndex) async throws -> [String: Double] {
        var costs: [String: Double] = [:]
        for row in try await index.rows("""
            SELECT u.conversation_id, u.model, SUM(u.input), SUM(u.output), SUM(u.cache_read),
                   SUM(u.cache_write_5m), SUM(u.cache_write_1h)
            FROM usage u GROUP BY u.conversation_id, u.model
            """) {
            guard let id = row.text(0), let model = row.text(1) else { continue }
            costs[id, default: 0] += Pricing.cost(model: model, input: row.int(2), output: row.int(3), cacheRead: row.int(4),
                                                  cacheWrite5m: row.int(5), cacheWrite1h: row.int(6))
        }
        return costs
    }

    /// Scratch folders sessions ran in aren't projects.
    static func isScratch(_ path: String, home: String) -> Bool {
        guard !path.hasPrefix(home + "/") else { return false }
        return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
    }

    /// Every project folder with conversations, most recently active first.
    public static func list(index: HistoryIndex, paths: HostPaths = .current) async throws -> [ProjectSummary] {
        let home = paths.home.path
        let costs = try await costs(index: index)
        var files: [String: Set<String>] = [:]
        for row in try await index.rows("""
            SELECT c.project_path, t.file_path FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
            WHERE t.file_path IS NOT NULL AND c.project_path IS NOT NULL
              AND t.name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
            """) {
            if let project = row.text(0), let file = row.text(1) { files[root(of: project), default: []].insert(file) }
        }
        var pulls: [String: Set<String>] = [:]
        for row in try await index.rows("""
            SELECT c.project_path, p.url FROM pull_requests p JOIN conversations c ON c.id = p.conversation_id
            WHERE c.project_path IS NOT NULL
            """) {
            if let project = row.text(0), let url = row.text(1) { pulls[root(of: project), default: []].insert(url) }
        }

        struct Tally { var conversations = 0; var places: [String: Int] = [:]; var accounts = Set<String>()
                       var first: Date?; var last: Date?; var cost = 0.0 }
        var tallies: [String: Tally] = [:]
        for row in try await index.rows("""
            SELECT id, project_path, kind, install_name, account_id, first_activity, last_activity FROM conversations
            WHERE project_path LIKE '/%' AND present = 1
            """) {
            guard let id = row.text(0), let project = row.text(1).map(root(of:)), !isScratch(project, home: home) else { continue }
            var tally = tallies[project] ?? Tally()
            tally.conversations += 1
            tally.places[HistorySearch.place(kind: row.text(2), install: row.text(3)), default: 0] += 1
            if let account = row.text(4) { tally.accounts.insert(account) }
            if let first = row.date(5) { tally.first = min(tally.first ?? first, first) }
            if let last = row.date(6) { tally.last = max(tally.last ?? last, last) }
            tally.cost += costs[id] ?? 0
            tallies[project] = tally
        }
        return tallies.map { path, tally in
            ProjectSummary(path: path, conversations: tally.conversations,
                           places: tally.places.sorted { $0.value > $1.value }.map(\.key),
                           accounts: tally.accounts.count, firstActivity: tally.first, lastActivity: tally.last,
                           cost: tally.cost, filesChanged: files[path]?.count ?? 0, pullRequests: pulls[path]?.count ?? 0)
        }
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    public static func detail(of summary: ProjectSummary, index: HistoryIndex, days: Int = 56,
                              paths: HostPaths = .current, now: Date = Date()) async throws -> ProjectDetail {
        let costs = try await costs(index: index)
        // The same rule the list counts by: a conversation belongs to the folder it ran in (or
        // the repository its worktree came from). A prefix match would pull every project
        // under a home-folder session into that one.
        let conversations = try await index.rows("""
            SELECT id, session_id, title, kind, install_name, last_activity, git_branch, project_path FROM conversations
            WHERE project_path IS NOT NULL AND present = 1 ORDER BY last_activity DESC
            """).compactMap { row -> ProjectDetail.Conversation? in
            guard let id = row.text(0), let project = row.text(7), root(of: project) == summary.path else { return nil }
            return .init(id: id, sessionID: row.text(1), title: row.text(2) ?? "Untitled",
                         place: HistorySearch.place(kind: row.text(3), install: row.text(4)),
                         lastActivity: row.date(5), cost: costs[id] ?? 0, branch: row.text(6))
        }
        let ids = conversations.map(\.id)
        let list = ids.map { _ in "?" }.joined(separator: ",")
        let idValues = ids.map(SQLiteValue.text)
        guard !ids.isEmpty else {
            return ProjectDetail(summary: summary, conversations: [], pullRequests: [], files: [], activity: [], memory: [])
        }
        let pulls = try await index.rows("""
            SELECT p.url, p.number, p.repository, c.title FROM pull_requests p JOIN conversations c ON c.id = p.conversation_id
            WHERE p.conversation_id IN (\(list)) ORDER BY p.timestamp DESC
            """, idValues)
        var seen = Set<String>()
        let pullRequests = pulls.compactMap { row -> ProjectDetail.PullRequest? in
            guard let url = row.text(0), seen.insert(url).inserted else { return nil }
            let name = row.text(2).flatMap { repo in row.intOrNil(1).map { "\(repo)#\($0)" } } ?? url
            return .init(url: url, name: name, conversationTitle: row.text(3) ?? "Untitled")
        }
        let files = try await index.rows("""
            SELECT file_path, COUNT(DISTINCT conversation_id), MAX(timestamp) FROM tool_calls
            WHERE conversation_id IN (\(list)) AND file_path IS NOT NULL
              AND name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
            GROUP BY file_path ORDER BY MAX(timestamp) DESC LIMIT 60
            """, idValues).compactMap { row -> ProjectDetail.File? in
            row.text(0).map { .init(path: $0, conversations: Int(row.int(1)), lastChanged: row.date(2)) }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        var perDay: [Date: Set<String>] = [:]
        for row in try await index.rows("""
            SELECT conversation_id, timestamp FROM messages
            WHERE conversation_id IN (\(list)) AND timestamp >= ? AND role = 'user'
            """, idValues + [.date(today.addingTimeInterval(-Double(days) * 86_400))]) {
            guard let id = row.text(0), let time = row.date(1) else { continue }
            perDay[calendar.startOfDay(for: time), default: []].insert(id)
        }
        let activity = (0..<days).reversed().compactMap { back -> (Date, Int)? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, perDay[day]?.count ?? 0)
        }

        let fm = FileManager.default
        var memory: [URL] = []
        let root = URL(fileURLWithPath: summary.path)
        for candidate in [root.appendingPathComponent("CLAUDE.md"), root.appendingPathComponent(".claude/CLAUDE.md"),
                          root.appendingPathComponent("CLAUDE.local.md")] where fm.fileExists(atPath: candidate.path) {
            memory.append(candidate)
        }
        let projectMemory = paths.claudeCodeConfigDir.appendingPathComponent("projects/\(PathEncoder.encode(summary.path))/memory")
        if fm.fileExists(atPath: projectMemory.path) { memory.append(projectMemory) }

        return ProjectDetail(summary: summary, conversations: conversations, pullRequests: pullRequests, files: files,
                             activity: activity, memory: memory)
    }
}
