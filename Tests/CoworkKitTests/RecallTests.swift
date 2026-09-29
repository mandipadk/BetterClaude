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
        }
    }
}
