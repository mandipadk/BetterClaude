import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Outside sources")
struct ExternalTests {

    @Test("Codex sessions join the timeline with their own titles, and only what was typed counts")
    func codex() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            let install = try #require(snapshot.installs.first { $0.kind == .external(.codex) })
            let session = try #require(snapshot.conversations.first { $0.installID == install.id })
            #expect(session.title == "Refunds post twice on webhook retry")
            #expect(session.projectName == "billing-service")
            #expect(!session.isTranscriptMissing)
            // No Claude reads Codex sessions until a door is opened to them, and there's one to open.
            #expect(session.accountID == ClaudeAccount.codex.id)
            #expect(snapshot.knownAccounts.contains(.codex))

            let scan = try #require(session.external).scan()
            #expect(scan.messages.map(\.role) == [.user, .assistant])
            #expect(!scan.messages.contains { $0.text.contains("environment_context") })
            #expect(scan.toolCalls.map(\.name) == ["shell"])

            try await index.update(from: snapshot)
            let hits = try await index.search("refund idempotent")
            #expect(hits.first?.conversationID == session.id)
            #expect(hits.first?.place == "Codex")
        }
    }

    static func export(in folder: URL) throws -> URL {
        let conversations: [[String: Any]] = [
            ["uuid": "web-1", "name": "Pick a name for the reading app", "created_at": "2026-08-01T10:00:00Z",
             "updated_at": "2026-08-01T10:05:00Z", "account": ["uuid": FixtureHome.personalAccount],
             "chat_messages": [
                ["uuid": "m1", "sender": "human", "text": "Names for a calm reading app?", "created_at": "2026-08-01T10:00:00Z",
                 "content": [["type": "text", "text": "Names for a calm reading app?"]],
                 "attachments": [["file_name": "brief.txt", "extracted_content": "Audience: slow readers who like marginalia."]]],
                ["uuid": "m2", "sender": "assistant", "text": "", "created_at": "2026-08-01T10:01:00Z",
                 "content": [["type": "text", "text": "Lamplight, Folio, or Marginalia."]]],
             ]],
            ["uuid": "web-2", "name": "", "created_at": "2026-08-02T09:00:00Z", "updated_at": "2026-08-02T09:00:00Z",
             "account": ["uuid": FixtureHome.personalAccount],
             "chat_messages": [["uuid": "n1", "sender": "human", "text": "Is sourdough starter alive?",
                                "created_at": "2026-08-02T09:00:00Z"]]],
        ]
        let export = folder.appendingPathComponent("data-2026-09-01", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: conversations).write(to: export.appendingPathComponent("conversations.json"))
        try Data("[]".utf8).write(to: export.appendingPathComponent("users.json"))
        return export
    }

    @Test("A claude.ai export imports once, reads back, and is searchable under its account")
    func claudeWeb() async throws {
        try await HistoryIndexTests.withSample { sample, _, index in
            let export = try Self.export(in: sample.root)
            let first = try ClaudeWebImport.importExport(at: export, paths: sample.paths)
            #expect(first.added == 2)
            #expect(try ClaudeWebImport.importExport(at: export, paths: sample.paths).unchanged == 2)

            let snapshot = await Catalog(paths: sample.paths).snapshot()
            let web = try #require(snapshot.installs.first { $0.kind == .external(.claudeWeb) })
            let imported = snapshot.conversations.filter { $0.installID == web.id }
            #expect(imported.count == 2)
            #expect(imported.allSatisfy { $0.accountID == FixtureHome.personalAccount })
            // An untitled conversation takes its first message as a title.
            #expect(imported.contains { $0.title == "Is sourdough starter alive?" })

            let named = try #require(imported.first { $0.title == "Pick a name for the reading app" })
            let readable = ReadableConversation(scan: try #require(named.external).scan(), model: nil)
            #expect(readable.messageCount == 2)

            try await index.update(from: snapshot)
            // An attachment's text is searchable along with the messages.
            let hits = try await index.search("marginalia", options: .init(accountIDs: [FixtureHome.personalAccount]))
            #expect(hits.first?.conversationID == named.id)
            #expect(hits.first?.place == "claude.ai")

            try ClaudeWebImport.removeAll(paths: sample.paths)
            #expect(await Catalog(paths: sample.paths).snapshot().installs.allSatisfy { $0.kind != .external(.claudeWeb) })
        }
    }

    @Test("The zip claude.ai sends imports the same as the folder inside it")
    func claudeWebZip() throws {
        try FixtureHomeTests.withSample { sample in
            let export = try Self.export(in: sample.root)
            let zip = sample.root.appendingPathComponent("export.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", export.path, zip.path]
            try process.run()
            process.waitUntilExit()
            #expect(try ClaudeWebImport.importExport(at: zip, paths: sample.paths).added == 2)
            #expect(throws: ClaudeWebImport.ImportError.self) {
                try ClaudeWebImport.importExport(at: sample.root.appendingPathComponent("home"), paths: sample.paths)
            }
        }
    }
}
