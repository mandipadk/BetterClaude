import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Recall")
struct RecallTests {

    static let personal = FixtureHome.personalAccount
    static let work = FixtureHome.workAccount

    @Test("Each account's Claude sees only its own history until a door is opened, one way")
    func walls() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let workOnly = try #require(snapshot.conversations.first { $0.accountID == Self.work })
            let word = try #require(HistorySearch.terms(in: workOnly.title).max { $0.count < $1.count })

            let access = RecallAccess.load(paths: sample.paths)
            let personal = Recall(index: index, accounts: access.allowed(for: Self.personal))
            let hidden = try await personal.search(query: word, project: nil, sinceDays: nil, limit: 20)
            #expect(!hidden.contains(workOnly.title))
            #expect(try await personal.read(id: workOnly.cliSessionId, from: nil, limit: 10)
                .contains("There's no conversation"))

            var opened = access
            opened.setDoor(from: Self.personal, to: Self.work, open: true)
            try opened.save(paths: sample.paths)
            let reloaded = RecallAccess.load(paths: sample.paths)
            #expect(reloaded.isOpen(from: Self.personal, to: Self.work))
            #expect(!reloaded.isOpen(from: Self.work, to: Self.personal))
            let both = Recall(index: index, accounts: reloaded.allowed(for: Self.personal))
            #expect(try await both.search(query: word, project: nil, sinceDays: nil, limit: 20).contains(workOnly.title))
        }
    }

    @Test("Reading a conversation pages through it and says where to continue")
    func pagesThroughAConversation() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let recall = Recall(index: index, accounts: [Self.personal])
            let conversation = try #require(snapshot.conversations.first {
                $0.title == "Retry failed webhook deliveries with backoff" })
            let first = try await recall.read(id: conversation.cliSessionId, from: nil, limit: 1)
            #expect(first.contains("[0] the person"))
            #expect(first.contains("Continue with start=1"))
            let second = try await recall.read(id: conversation.cliSessionId, from: 1, limit: 5)
            #expect(second.contains("[1] Claude"))
            #expect(!second.contains("[0]"))
        }
    }

    @Test("Recent work lists what was first asked, and search names where it happened")
    func recentAndPlaces() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let recall = Recall(index: index, accounts: [Self.personal])
            let recent = try await recall.recent(project: "billing", days: 60, limit: 5)
            #expect(recent.contains("Retry failed webhook deliveries with backoff"))
            #expect(recent.contains("first asked: Webhook deliveries"))
            #expect(recent.contains("pull requests: https://github.com/northwind/billing-service/pull/318"))
            let found = try await recall.search(query: "backoff", project: nil, sinceDays: nil, limit: 5)
            #expect(found.contains("Claude Code, in"))
        }
    }

    @Test("A file's history lists the conversations whose tools touched it")
    func fileHistory() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let rows = try await index.rows("""
                SELECT t.file_path FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
                WHERE t.file_path IS NOT NULL AND c.account_id = ? LIMIT 1
                """, [.text(Self.personal)])
            let path = try #require(rows.first?.text(0))
            let recall = Recall(index: index, accounts: [Self.personal])
            #expect(try await recall.fileHistory(path: path).contains("tools:"))
            #expect(try await recall.fileHistory(path: (path as NSString).lastPathComponent).contains(path))
            #expect(try await Recall(index: index, accounts: [Self.work]).fileHistory(path: path)
                .contains("No past conversation"))
        }
    }

    @Test("Connecting a Desktop install adds one entry beside the others, and disconnecting removes only it")
    func desktopConnection() throws {
        try FixtureHomeTests.withSample { sample in
            let snapshot = CatalogSnapshot(installs: InstallDiscovery.all(), paths: sample.paths)
            let claude = try #require(snapshot.installs.first { $0.name == "Claude" })
            let target = try #require(RecallConnection.target(for: claude, paths: sample.paths))
            let config = claude.dataRoot.appendingPathComponent("claude_desktop_config.json")
            try Data(#"{"mcpServers": {"notes": {"command": "/bin/notes"}}, "theme": "dark"}"#.utf8).write(to: config)

            let server = URL(fileURLWithPath: "/Applications/BetterClaude.app/Contents/MacOS/bc-recall")
            try RecallConnection.connect(target, server: server, account: Self.personal, paths: sample.paths)
            let registered = try #require(RecallConnection.registration(target, paths: sample.paths))
            #expect(registered.command == server.path)
            #expect(registered.arguments == ["--account", Self.personal])
            let connected = try JSONValue.parse(Data(contentsOf: config))
            #expect(connected["mcpServers"]?["notes"]?["command"]?.stringValue == "/bin/notes")
            #expect(connected["theme"]?.stringValue == "dark")

            try RecallConnection.disconnect(target, paths: sample.paths)
            #expect(!RecallConnection.isConnected(target, paths: sample.paths))
            #expect(try JSONValue.parse(Data(contentsOf: config)) == (try JSONValue.parse(
                Data(#"{"mcpServers": {"notes": {"command": "/bin/notes"}}, "theme": "dark"}"#.utf8))))
        }
    }

    @Test("A connection is written again when its install signs into another account")
    func reconnectsOnAccountChange() throws {
        try FixtureHomeTests.withSample { sample in
            let snapshot = CatalogSnapshot(installs: InstallDiscovery.all(), paths: sample.paths)
            let claude = try #require(snapshot.installs.first { $0.name == "Claude" })
            let target = try #require(RecallConnection.target(for: claude, paths: sample.paths))
            let server = URL(fileURLWithPath: "/bin/sh")
            try RecallConnection.connect(target, server: server, account: Self.personal, paths: sample.paths)
            let before = try #require(RecallConnection.registration(target, paths: sample.paths))
            #expect(!RecallConnection.needsRepair(before, server: server, account: Self.personal))
            #expect(RecallConnection.needsRepair(before, server: server, account: Self.work))

            try RecallConnection.connect(target, server: server, account: Self.work, paths: sample.paths)
            let after = try #require(RecallConnection.registration(target, paths: sample.paths))
            #expect(after.arguments == ["--account", Self.work])
            #expect(!RecallConnection.needsRepair(after, server: server, account: Self.work))
            // Better Claude moved, and the copy it named is gone.
            #expect(RecallConnection.needsRepair((command: "/srv/gone/bc-recall", arguments: after.arguments),
                                                 server: server, account: Self.work))
        }
    }

    @Test("A server started by a Desktop copy answers for that copy's account")
    func consumerFromEnvironment() {
        var access = RecallAccess()
        access.installAccounts = ["/Volumes/Sample/Parallex/instances/work/data": Self.work]
        #expect(access.consumer(registered: Self.personal, environment: [:]) == Self.personal)
        #expect(access.consumer(registered: Self.personal, environment: [
            "CLAUDE_USER_DATA_DIR": "/Volumes/Sample/Parallex/instances/work/data"]) == Self.work)
        #expect(access.consumer(registered: Self.personal, environment: ["CLAUDE_USER_DATA_DIR": "/elsewhere"]) == Self.personal)
    }

    @Test("A handoff brief carries what it was about, the files changed, and the last exchange")
    func handoff() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first {
                $0.title == "Retry failed webhook deliveries with backoff" })
            let material = try #require(try await Handoff.material(for: conversation.id, index: index))
            #expect(material.firstAsk?.hasPrefix("Webhook deliveries that fail") == true)
            #expect(material.lastAsk == "Can we cap the total wait at ten minutes?")
            #expect(material.filesChanged.contains { $0.hasSuffix("deliver.ts") })
            let brief = Handoff.draft(material, home: sample.paths)
            #expect(brief.hasPrefix("# Handoff: Retry failed webhook deliveries with backoff"))
            #expect(brief.contains("## Files changed"))
            #expect(brief.contains("~/Code/billing-service/src/webhooks/deliver.ts"))
            #expect(brief.contains("**Asked:** Can we cap the total wait at ten minutes?"))
            #expect(try await Handoff.material(for: "nope", index: index) == nil)
            #expect(Handoff.sectionsOnly("# Handoff: X\n**Who:** a model\n\n---\n## Goal\n- Ship it\n---\n## Next step\n- Test") ==
                    "## Goal\n- Ship it\n## Next step\n- Test")
        }
    }
}

@Suite("Handoff and Ask details")
struct HandoffDetailTests {

    /// One conversation whose rows include a compaction and a recap, and end on an ask.
    static func index(endingWithReply: Bool) async throws -> HistoryIndex {
        let index = try HistoryIndex(url: nil)
        let rows: [(String, String, String)] = [
            ("user", "message", "Plan the migration"),
            ("assistant", "message", "Three steps."),
            ("user", "compaction", "We planned a migration."),
            ("system", "recap", "Step one is next."),
            ("user", "message", "Start step one"),
        ] + (endingWithReply ? [("assistant", "message", "Step one is done.")] : [])
        _ = try await index.rows("""
            INSERT INTO conversations (id, session_id, install_id, account_id, kind, title, last_activity, present, message_count)
            VALUES ('c1', 's1', 'install', 'acct', 'claudeCode', 'Migration', ?, 1, ?)
            """, [.date(Date()), .int(Int64(rows.count))])
        for (ordinal, row) in rows.enumerated() {
            _ = try await index.rows("INSERT INTO messages (conversation_id, ordinal, role, kind, text) VALUES ('c1', ?, ?, ?, ?)",
                                     [.int(Int64(ordinal)), .text(row.0), .text(row.1), .text(row.2)])
        }
        return index
    }

    @Test("A handoff leaves out the reply when the conversation ends on an unanswered ask")
    func unansweredAsk() async throws {
        let open = try #require(try await Handoff.material(for: "c1", index: try await Self.index(endingWithReply: false)))
        #expect(open.lastAsk == "Start step one")
        #expect(open.lastReply == nil)
        #expect(!Handoff.draft(open).contains("**Claude:**"))

        let answered = try #require(try await Handoff.material(for: "c1", index: try await Self.index(endingWithReply: true)))
        #expect(answered.lastReply == "Step one is done.")
    }

    @Test("Message counts leave out compactions and recaps")
    func messageCounts() async throws {
        let index = try await Self.index(endingWithReply: true)
        let material = try #require(try await Handoff.material(for: "c1", index: index))
        #expect(material.messageCount == 4)
        #expect(Handoff.draft(material).contains(". 4 messages"))

        let read = try await Recall(index: index, accounts: ["acct"]).read(id: "s1", from: 0, limit: 2)
        #expect(read.contains("messages: 4\n"))
        #expect(read.contains("(4 more messages. Continue with start=2.)"))
    }

    @Test("Every source an answer cites is listed, ranges and lists included")
    func citations() {
        #expect(AskRetrieval.citedNumbers(in: "You chose SQLite [1]. Later [2, 4] and [5-7] revisited it.")
                == [1, 2, 4, 5, 6, 7])
        #expect(AskRetrieval.citedNumbers(in: "See [3–4] and [ 6 ]") == [3, 4, 6])
        #expect(AskRetrieval.citedNumbers(in: "An array a[i] and [x, 1] cite nothing").isEmpty)
    }

    @Test("A question of only common words has nothing to search for")
    func onlyCommonWords() async throws {
        #expect(AskRetrieval.keywords(in: "What did we decide about that?").isEmpty)
        let index = try await Self.index(endingWithReply: true)
        let found = try await AskRetrieval.gather(question: "What did we decide about that?", index: index)
        #expect(found.sources.isEmpty)
    }

    @Test("Ask only offers sources that are still there to open")
    func absentSourcesAreLeftOut() async throws {
        let index = try await Self.index(endingWithReply: true)
        #expect(try await AskRetrieval.gather(question: "migration plan", index: index).sources.map(\.conversationID) == ["c1"])
        _ = try await index.rows("UPDATE conversations SET present = 0 WHERE id = 'c1'")
        #expect(try await AskRetrieval.gather(question: "migration plan", index: index).sources.isEmpty)
    }
}
