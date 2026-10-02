import Foundation
import Testing

@testable import CoworkKit

/// An in-memory index written to directly: conversations, and what's in them.
private struct Rows {
    let index: HistoryIndex

    init() throws { index = try HistoryIndex(url: nil) }

    func conversation(_ id: String, account: String = "a", install: String = "cli", started: Date?,
                      project: String? = "/srv/app") async throws {
        _ = try await index.rows("""
            INSERT INTO conversations (id, install_id, account_id, kind, title, project_path, first_activity, last_activity)
            VALUES (?, ?, ?, 'claudeCode', ?, ?, ?, ?)
            """, [.text(id), .text(install), .text(account), .text("Conversation \(id)"), .optional(project),
                  .date(started), .date(started)])
    }

    func reply(_ conversation: String, _ message: String, at: Date?, model: String = "claude-opus-5",
               output: Int64 = 1_000_000) async throws {
        _ = try await index.rows("""
            INSERT INTO usage (conversation_id, message_id, model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h)
            VALUES (?, ?, ?, ?, 0, ?, 0, 0, 0)
            """, [.text(conversation), .text(message), .text(model), .date(at), .int(output)])
    }

    func message(_ conversation: String, _ uuid: String, at: Date, role: String = "user", kind: String = "message",
                 text: String = "Make it so") async throws {
        _ = try await index.rows("""
            INSERT INTO messages (conversation_id, ordinal, uuid, role, kind, timestamp, text)
            VALUES (?, (SELECT COUNT(*) FROM messages WHERE conversation_id = ?), ?, ?, ?, ?, ?)
            """, [.text(conversation), .text(conversation), .text(uuid), .text(role), .text(kind), .date(at), .text(text)])
    }

    func tool(_ conversation: String, _ id: String, _ name: String, at: Date, file: String? = nil) async throws {
        _ = try await index.rows("""
            INSERT INTO tool_calls (conversation_id, timestamp, name, file_path, tool_use_id) VALUES (?, ?, ?, ?, ?)
            """, [.text(conversation), .date(at), .text(name), .optional(file), .text(id)])
    }
}

@Suite("Copied replies, prompts and tool calls")
struct CopiedRowsTests {

    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// How copies were told apart before the index marked them: every row ranked each time.
    static let rankedEveryTime = """
        (SELECT * FROM (SELECT usage.*, ROW_NUMBER() OVER (PARTITION BY message_id ORDER BY
            timestamp IS NULL, timestamp,
            (SELECT first_activity FROM conversations WHERE id = usage.conversation_id) IS NULL,
            (SELECT first_activity FROM conversations WHERE id = usage.conversation_id),
            usage.rowid) AS copy FROM usage) WHERE copy = 1)
        """

    @Test("The index marks copies as it changes, exactly as ranking every row would, and much faster to read")
    func marksCopies() async throws {
        let index = try HistoryIndex(url: nil)
        // 3,000 conversations, many starting at the same minute and some at no known time;
        // 35,000 replies, some without a time; every 25th copied into another conversation
        // and every 100th into a third.
        _ = try await index.rows("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 2999)
            INSERT INTO conversations (id, install_id, account_id, kind, title, first_activity, last_activity)
            SELECT 'c' || i, 'cli', 'a', 'claudeCode', 'Conversation',
                   CASE WHEN i % 101 = 0 THEN NULL ELSE 1790000000 + (i * 37 % 500) * 60 END, 1790000000 FROM n
            """)
        let filling = ContinuousClock.now
        _ = try await index.rows("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 35000)
            INSERT INTO usage (conversation_id, message_id, model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h)
            SELECT 'c' || (i % 3000), 'm' || i, CASE WHEN i % 3 = 0 THEN 'claude-sonnet-5' ELSE 'claude-opus-5' END,
                   CASE WHEN i % 997 = 0 THEN NULL ELSE 1790000000 + i * 60 END, i % 50, i % 70, i * 3 % 1000, 0, 0 FROM n
            """)
        let filled = ContinuousClock.now - filling
        for (every, shift) in [(25, 7), (100, 13)] {
            _ = try await index.rows("""
                INSERT INTO usage (conversation_id, message_id, model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h)
                SELECT 'c' || ((CAST(substr(message_id, 2) AS INTEGER) + \(shift)) % 3000), message_id, model, timestamp,
                       input, output, cache_read, cache_write_5m, cache_write_1h
                FROM usage WHERE CAST(substr(message_id, 2) AS INTEGER) % \(every) = 0
                  AND conversation_id = 'c' || (CAST(substr(message_id, 2) AS INTEGER) % 3000)
                """)
        }

        func same() async throws -> Bool {
            let key = "SELECT conversation_id || '/' || message_id FROM %@ ORDER BY 1"
            let old = try await index.rows(key.replacingOccurrences(of: "%@", with: Self.rankedEveryTime)).map { $0.text(0) }
            let new = try await index.rows(key.replacingOccurrences(of: "%@", with: DistinctUsage.table)).map { $0.text(0) }
            return old == new && old.count == 35_000
        }
        #expect(try await index.rows("SELECT COUNT(*) FROM usage").first?.int(0) == 36_750)
        #expect(try await same())

        // Everything that changes which appearance comes first: a conversation's start moving
        // or going unknown, a conversation forgotten, replies read again, a conversation removed.
        _ = try await index.rows("UPDATE conversations SET first_activity = 1789000000 WHERE id IN ('c7', 'c50', 'c107', 'c400')")
        _ = try await index.rows("UPDATE conversations SET first_activity = NULL WHERE id IN ('c32', 'c57')")
        _ = try await index.rows("DELETE FROM usage WHERE conversation_id = 'c25'")
        _ = try await index.rows("""
            INSERT OR REPLACE INTO usage (conversation_id, message_id, model, timestamp, input, output, cache_read,
                                          cache_write_5m, cache_write_1h)
            SELECT conversation_id, message_id, model, timestamp, input, output, cache_read, cache_write_5m, cache_write_1h
            FROM usage WHERE conversation_id IN ('c100', 'c113')
            """)
        _ = try await index.rows("DELETE FROM conversations WHERE id = 'c75'")
        let distinctLeft = try await index.rows("SELECT COUNT(DISTINCT message_id) FROM usage").first?.int(0)
        let old = try await index.rows("SELECT conversation_id || '/' || message_id FROM \(Self.rankedEveryTime) ORDER BY 1")
        let new = try await index.rows("SELECT conversation_id || '/' || message_id FROM \(DistinctUsage.table) ORDER BY 1")
        #expect(old.map { $0.text(0) } == new.map { $0.text(0) } && Int64(new.count) == distinctLeft)

        // A week's totals, the way Usage reads them.
        let week = """
            SELECT conversation_id, model, SUM(output) FROM %@ WHERE timestamp >= ? AND timestamp < ?
            GROUP BY conversation_id, model ORDER BY 1, 2
            """
        let range: [SQLiteValue] = [.int(1_790_000_000 + 35_000 * 60 - 7 * 86_400), .int(1_790_000_000 + 35_000 * 60)]
        func timed(_ table: String) async throws -> (Duration, [String]) {
            var best = Duration.seconds(60)
            var result: [String] = []
            for _ in 0..<3 {
                let began = ContinuousClock.now
                result = try await index.rows(week.replacingOccurrences(of: "%@", with: table), range)
                    .map { "\($0.text(0) ?? "")/\($0.text(1) ?? ""):\($0.int(2))" }
                best = min(best, ContinuousClock.now - began)
            }
            return (best, result)
        }
        let (ranked, rankedRows) = try await timed(Self.rankedEveryTime)
        let (marked, markedRows) = try await timed(DistinctUsage.table)
        #expect(rankedRows == markedRows && !markedRows.isEmpty)
        #expect(marked * 3 < ranked, "marked \(marked), ranked \(ranked)")
        print("Week of 36,750 replies: ranked every time \(ranked), marked \(marked); marking 35,000 on insert took \(filled)")
    }

    @Test("A project's conversations add up to the project, and the reader says what was copied")
    func projectsAddUp() async throws {
        let rows = try Rows()
        let start = Self.start
        try await rows.conversation("original", started: start, project: "/srv/code/app")
        try await rows.conversation("resumed", started: start.addingTimeInterval(3_600),
                                    project: "/srv/code/app/.claude/worktrees/fix")
        try await rows.conversation("elsewhere", started: start, project: "/srv/work/app")
        for conversation in ["original", "resumed"] {
            try await rows.reply(conversation, "m1", at: start.addingTimeInterval(60))
            try await rows.reply(conversation, "m2", at: start.addingTimeInterval(120))
        }
        try await rows.reply("resumed", "m3", at: start.addingTimeInterval(3_700))
        try await rows.reply("elsewhere", "m4", at: start.addingTimeInterval(60))

        let paths = HostPaths.fixture(at: FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)"))
        let projects = try await Projects.list(index: rows.index, paths: paths)
        let code = try #require(projects.first { $0.path == "/srv/code/app" })
        // Opus 5 output is $25 a million: each reply once.
        #expect(abs(code.cost - 75) < 1e-9 && code.conversations == 2)
        let detail = try await Projects.detail(of: code, index: rows.index, paths: paths, now: start)
        #expect(abs(detail.conversations.reduce(0) { $0 + $1.cost } - code.cost) < 1e-9)

        // Usage groups the worktree with its repository and tells the two apps apart.
        let items = try await QuotaAttribution.items(index: rows.index, accountIDs: ["a"], since: start)
        let byProject = QuotaAttribution.byProject(items)
        #expect(Set(byProject.map(\.name)) == ["app (code)", "app (work)"])
        #expect(byProject.first { $0.name == "app (code)" }.map { abs($0.cost - 75) < 1e-9 && $0.conversations == 2 } == true)

        let record = try await FlightRecord.load(conversationID: "resumed", index: rows.index)
        #expect(abs(record.totalCost - 25) < 1e-9 && abs(record.copiedCost - 50) < 1e-9 && record.ownReplies == 1)
    }

    @Test("Folders with the same name are told apart by the folder they're in")
    func projectNames() {
        #expect(Projects.names(for: ["/srv/code/app", "/srv/work/app", "/srv/site"])
                == ["/srv/code/app": "app (code)", "/srv/work/app": "app (work)", "/srv/site": "site"])
        #expect(Projects.names(for: ["/srv/a/x/app", "/srv/b/x/app"])
                == ["/srv/a/x/app": "app (/srv/a/x)", "/srv/b/x/app": "app (/srv/b/x)"])
    }

    @Test("A month counts copied prompts, tool calls and compactions once, and every project")
    func month() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 9))!
        let rows = try Rows()
        try await rows.conversation("original", started: day, project: "/srv/code/app")
        try await rows.conversation("resumed", started: day.addingTimeInterval(86_400),
                                    project: "/srv/code/app/.claude/worktrees/fix")
        try await rows.conversation("elsewhere", started: day, project: "/srv/work/app")
        for conversation in ["original", "resumed"] {
            try await rows.message(conversation, "p1", at: day)
            try await rows.message(conversation, "p2", at: day.addingTimeInterval(600))
            try await rows.message(conversation, "k1", at: day.addingTimeInterval(700), role: "assistant", kind: "compaction")
            try await rows.tool(conversation, "t1", "Edit", at: day.addingTimeInterval(60), file: "/srv/code/app/a.swift")
            try await rows.reply(conversation, "r1", at: day.addingTimeInterval(30))
        }
        try await rows.message("resumed", "p3", at: day.addingTimeInterval(86_400 + 3_600))
        try await rows.tool("resumed", "t2", "mcp__linear__search", at: day.addingTimeInterval(86_400 + 3_660))
        try await rows.message("elsewhere", "p4", at: day.addingTimeInterval(7_200))
        try await rows.tool("elsewhere", "t3", "mcp__notion__search", at: day.addingTimeInterval(7_260))
        for number in 1...5 {
            try await rows.conversation("side\(number)", started: day, project: "/srv/side\(number)")
            try await rows.message("side\(number)", "s\(number)", at: day.addingTimeInterval(Double(number) * 3_600))
        }

        let stats = try await MonthStats.build(index: rows.index, month: day, calendar: calendar)
        #expect(stats.prompts == 9 && stats.conversations == 8)
        #expect(stats.hours.reduce(0, +) == 9 && stats.days[9] == 7 && stats.days[10] == 1)
        #expect(stats.compactions == 1 && stats.replies == 1)
        #expect(stats.tools.map(\.name).sorted() == ["Edit", "search"])
        #expect(stats.tools.first { $0.name == "search" }?.uses == 2 && stats.tools.first { $0.name == "Edit" }?.uses == 1)
        #expect(stats.projects.count == 5 && stats.projectCount == 7)
        #expect(stats.projects.first?.name == "app (code)" && stats.projects.first?.conversations == 2)
    }

    @Test("A week's work is the conversations with a prompt in it, for the accounts and stretch asked about")
    func week() async throws {
        let start = Self.start
        let rows = try Rows()
        try await rows.conversation("original", started: start, project: "/srv/code/app")
        try await rows.conversation("resumed", started: start.addingTimeInterval(3_600),
                                    project: "/srv/code/app/.claude/worktrees/fix")
        try await rows.conversation("elsewhere", started: start, project: "/srv/work/app")
        try await rows.conversation("quiet", started: start.addingTimeInterval(-30 * 86_400), project: "/srv/quiet")
        try await rows.conversation("theirs", account: "b", started: start, project: "/srv/theirs")
        _ = try await rows.index.rows("UPDATE conversations SET last_activity = ? WHERE id = 'quiet'",
                                      [.date(start.addingTimeInterval(86_400))])
        try await rows.message("quiet", "q1", at: start.addingTimeInterval(-30 * 86_400))
        try await rows.reply("quiet", "qr", at: start.addingTimeInterval(86_400))
        for conversation in ["original", "resumed"] {
            try await rows.message(conversation, "p1", at: start.addingTimeInterval(60))
            try await rows.tool(conversation, "t1", "Bash", at: start.addingTimeInterval(90))
            try await rows.message(conversation, "r1", at: start.addingTimeInterval(120), role: "system", kind: "recap",
                                   text: "Recap of the first stretch")
        }
        try await rows.message("resumed", "p2", at: start.addingTimeInterval(7_200))
        try await rows.message("elsewhere", "p3", at: start.addingTimeInterval(600))
        try await rows.message("elsewhere", "p4", at: start.addingTimeInterval(9 * 86_400))
        try await rows.message("theirs", "p5", at: start.addingTimeInterval(600))

        let digest = try await WeekDigest.build(index: rows.index, spans: [
            WeekDigest.Span(accountIDs: ["a"], since: start, until: start.addingTimeInterval(7 * 86_400)),
        ])
        #expect(digest.conversations == 3 && digest.prompts == 3 && digest.commands == 1)
        #expect(digest.recaps == ["Recap of the first stretch"])
        #expect(digest.projects.map(\.name) == ["app (code)", "app (work)"])
        #expect(digest.projects.first?.conversations == 2)

        let everyone = try await WeekDigest.build(index: rows.index, since: start)
        #expect(everyone.conversations == 4 && everyone.prompts == 5)
    }

    @Test("A failure counts the sessions it happened in, and its detail comes from this install this week")
    func doctor() async throws {
        let start = Self.start
        let rows = try Rows()
        try await rows.conversation("one", started: start)
        try await rows.conversation("two", started: start)
        try await rows.conversation("other", install: "desktop", started: start)
        func failed(_ conversation: String, _ detail: String, at: Date) async throws {
            _ = try await rows.index.rows("""
                INSERT INTO health (conversation_id, kind, name, detail, timestamp) VALUES (?, 'mcpFailed', 'notes', ?, ?)
                """, [.text(conversation), .text(detail), .date(at)])
        }
        try await failed("one", "LONG_AGO", at: start.addingTimeInterval(-30 * 86_400))
        for minute in 1...3 { try await failed("one", "ECONNREFUSED", at: start.addingTimeInterval(Double(minute) * 60)) }
        try await failed("two", "ENOENT", at: start.addingTimeInterval(600))
        try await failed("other", "ELSEWHERE", at: start.addingTimeInterval(900))

        let issues = try await Doctor.issues(index: rows.index, installIDs: ["cli"], since: start)
        #expect(issues.count == 1 && issues.first?.sessions == 2 && issues.first?.detail == "ENOENT")
    }

    @Test("A fallback or /model recorded just after the first reply on the new model still explains it")
    func lateMarkers() async throws {
        let start = Self.start
        let rows = try Rows()
        try await rows.conversation("drifty", started: start)
        let replies: [(Double, String)] = [(0, "claude-sonnet-5"), (60, "claude-opus-5"), (60.5, "claude-opus-5"),
                                           (200, "claude-sonnet-5"), (300, "claude-sonnet-5"), (400, "claude-opus-5")]
        for (offset, (at, model)) in replies.enumerated() {
            try await rows.reply("drifty", "m\(offset)", at: start.addingTimeInterval(at), model: model)
        }
        for (kind, at) in [("fallback", 60.1), ("requested", 201.5), ("requested", 420.0)] {
            _ = try await rows.index.rows("INSERT INTO model_markers (conversation_id, kind, timestamp) VALUES ('drifty', ?, ?)",
                                          [.text(kind), .date(start.addingTimeInterval(at))])
        }
        let switches = try await ModelDrift.switches(conversationID: "drifty", index: rows.index)
        #expect(switches.map(\.cause) == [.fallback, .requested, .unexplained])
    }

    @Test("A decision repeated in a resumed conversation is credited to where it was first said")
    func decisions() async throws {
        let start = Self.start
        let rows = try Rows()
        // The copy is indexed first, and its id sorts first.
        try await rows.conversation("a-resumed", started: start.addingTimeInterval(3_600))
        try await rows.conversation("z-original", started: start)
        for conversation in ["a-resumed", "z-original"] {
            try await rows.message(conversation, "d1", at: start.addingTimeInterval(60), text: "Let's go with Postgres for this.")
        }
        let paths = HostPaths.fixture(at: FileManager.default.temporaryDirectory.appendingPathComponent("decisions-\(UUID().uuidString)"))
        let decisions = try await Decisions.list(index: rows.index, paths: paths)
        #expect(decisions.count == 1 && decisions.first?.conversationID == "z-original")
    }

    @Test("A snippet repeated in a resumed conversation is credited to the conversation that began first")
    func libraryCredit() {
        func artifact(_ conversation: String, started: Date) -> Artifact {
            var made = Artifact(id: "hash#\(conversation)", kind: .code, title: "retry.swift", language: "swift", bytes: 10,
                                lineCount: 1, contentHash: "hash", inlineContent: "retry()", fileURL: nil,
                                conversationTitle: conversation, conversationID: conversation, container: "Claude",
                                createdAt: Self.start)
            made.conversationStarted = started
            return made
        }
        let copy = artifact("a-resumed", started: Self.start.addingTimeInterval(3_600))
        let original = artifact("z-original", started: Self.start.addingTimeInterval(-60))
        #expect(ArtifactHarvest.deduplicate([copy, original]).kept.first?.conversationID == "z-original")
        #expect(ArtifactHarvest.deduplicate([original, copy]).kept.first?.conversationID == "z-original")
    }
}
