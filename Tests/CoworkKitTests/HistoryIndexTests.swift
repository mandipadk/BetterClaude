import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("History index")
struct HistoryIndexTests {

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func reply(id: String, uuid: String, blocks: [[String: Any]], output: Int = 10) -> String {
        line(["type": "assistant", "uuid": uuid, "timestamp": "2026-09-01T10:00:00.000Z",
              "message": ["id": id, "model": "claude-opus-5-5", "role": "assistant", "content": blocks,
                          "usage": ["input_tokens": 3, "output_tokens": output, "cache_read_input_tokens": 100,
                                    "cache_creation_input_tokens": 50,
                                    "cache_creation": ["ephemeral_5m_input_tokens": 0,
                                                       "ephemeral_1h_input_tokens": 50]]]])
    }

    @Test("A reply split across records is counted once, and tool calls keep their file")
    func scansUsageAndTools() {
        let text = [
            line(["type": "user", "uuid": "u1", "timestamp": "2026-09-01T09:59:00.000Z",
                  "message": ["role": "user", "content": "Fix the retry cap"]]),
            reply(id: "msg_1", uuid: "a1", blocks: [["type": "text", "text": "Looking at it."]], output: 5),
            reply(id: "msg_1", uuid: "a2", blocks: [["type": "tool_use", "id": "t1", "name": "Edit",
                                                    "input": ["file_path": "/p/retry.swift"]]], output: 40),
            line(["type": "system", "subtype": "away_summary", "isMeta": true, "uuid": "s1",
                  "content": "Raised the retry cap to five."]),
            line(["type": "user", "isCompactSummary": true, "uuid": "c1",
                  "message": ["role": "user", "content": "Summary of the earlier conversation"]]),
            line(["type": "cost-state", "totalCostUSD": 1.25, "totalLinesAdded": 12, "totalLinesRemoved": 3]),
            line(["type": "ai-title", "aiTitle": "Retry cap"]),
        ].joined(separator: "\n") + "\n" + #"{"type":"user","message":{"content":"half a li"#

        let scan = TranscriptScanner.scan(Data(text.utf8))
        #expect(scan.usage.count == 1)
        #expect(scan.usage.first?.output == 40)
        #expect(scan.usage.first?.cacheWrite1h == 50)
        #expect(scan.toolCalls.map(\.filePath) == ["/p/retry.swift"])
        #expect(scan.messages.map(\.kind) == [.message, .message, .recap, .compaction])
        #expect(scan.cost?.totalUSD == 1.25)
        #expect(scan.title == "Retry cap")
        // The half-written last line waits for the next pass.
        #expect(scan.endOffset == Int64(text.utf8.count - #"{"type":"user","message":{"content":"half a li"#.utf8.count))
    }

    static func withSample(_ body: (FixtureHome, CatalogSnapshot, HistoryIndex) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()
        try await HostPaths.$current.withValue(sample.paths) {
            let snapshot = await Catalog(paths: sample.paths).snapshot()
            let index = try HistoryIndex(url: HistoryIndex.defaultURL(paths: sample.paths))
            try await body(sample, snapshot, index)
        }
    }

    @Test("The sample Mac indexes, searches, and only re-reads what changed")
    func indexesTheSample() async throws {
        try await Self.withSample { _, snapshot, index in
            let read = try await index.update(from: snapshot)
            #expect(read == snapshot.conversations.filter { $0.transcriptURL != nil }.count)
            let summary = try await index.summary()
            #expect(summary.conversations == snapshot.conversations.count)
            #expect(summary.messages > 20)

            let hits = try await index.search("webhook backoff")
            #expect(hits.first?.title == "Retry failed webhook deliveries with backoff")
            #expect(hits.first?.excerpts.isEmpty == false)
            // Prefixes match: "webho" finds "webhook".
            #expect(try await index.search("webho").contains { $0.title.contains("webhook") })
            // Every word has to be there somewhere.
            #expect(try await index.search("webhook lisbon").isEmpty)

            #expect(try await index.update(from: snapshot) == 0)
        }
    }

    @Test("A conversation that grew is read from where the last pass stopped")
    func readsOnlyTheTail() async throws {
        try await Self.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first {
                $0.title == "Retry failed webhook deliveries with backoff" })
            let url = try #require(conversation.transcriptURL)
            let before = try await index.messages(in: conversation.id).count

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line(["type": "user", "uuid": "late",
                                                     "message": ["role": "user", "content": "Also log the zebra case"]]) + "\n").utf8))
            try handle.close()

            #expect(try await index.update(from: snapshot) == 1)
            let after = try await index.messages(in: conversation.id)
            #expect(after.count == before + 1)
            #expect(after.last?.ordinal == before)
            #expect(try await index.search("zebra").first?.conversationID == conversation.id)
        }
    }

    @Test("A transcript Claude Code deleted stays searchable on request")
    func keepsDeletedConversations() async throws {
        try await Self.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first {
                $0.title == "Retry failed webhook deliveries with backoff" })
            try FileManager.default.removeItem(at: try #require(conversation.transcriptURL))

            let later = await Catalog(paths: sample.paths).snapshot()
            try await index.update(from: later)
            #expect(try await index.search("webhook backoff").isEmpty)
            let kept = try await index.search("webhook backoff", options: .init(includeAbsent: true))
            #expect(kept.first?.conversationID == conversation.id)
            #expect(kept.first?.isPresent == false)
        }
    }

    @Test("Queries ignore case, an empty query finds nothing, and titles outrank messages")
    func ranking() async throws {
        try await Self.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            #expect(try await index.search("   ").isEmpty)
            #expect(try await index.search("WEBHOOK").first?.title == "Retry failed webhook deliveries with backoff")
            let hits = try await index.search("backoff")
            let titled = try #require(hits.firstIndex { $0.title.localizedCaseInsensitiveContains("backoff") })
            #expect(titled == 0)
        }
    }

    @Test("Tokens are recorded once per reply")
    func recordsUsage() async throws {
        try await Self.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let rows = try await index.rows("SELECT COUNT(*), COUNT(DISTINCT message_id), SUM(output) FROM usage")
            #expect(rows.first?.int(0) == rows.first?.int(1))
            #expect((rows.first?.int(2) ?? 0) > 0)
        }
    }

    @Test("Another process can read the index after the app that wrote it has quit")
    func readsAfterTheWriterCloses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history-v\(HistoryIndex.schemaVersion).sqlite")
        do { _ = try HistoryIndex(url: url) }
        // What a clean close leaves behind: no shared-memory or write-ahead file.
        for suffix in ["-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let reader = try HistoryIndex(readingFrom: url)
        #expect(try await reader.summary().conversations == 0)
    }

    @Test("An older version's index is cleared away, never rebuilt in place")
    func separatesVersions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in ["history.sqlite", "history.sqlite-wal", "history-v1.sqlite"] {
            try Data("old".utf8).write(to: folder.appendingPathComponent(old))
        }
        _ = try HistoryIndex(url: folder.appendingPathComponent("history-v\(HistoryIndex.schemaVersion).sqlite"))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.allSatisfy { $0.hasPrefix("history-v\(HistoryIndex.schemaVersion)") })
    }
}
