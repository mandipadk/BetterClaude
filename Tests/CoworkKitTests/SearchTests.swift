import Foundation
import Testing

@testable import CoworkKit

@Suite("Conversation text")
struct SearchTests {

    private func message(_ role: String, _ text: String, uuid: String) -> JSONValue {
        .object(JSONObject([
            ("type", .string(role)),
            ("uuid", .string(uuid)),
            ("timestamp", .string("2026-03-11T20:56:15.545Z")),
            ("message", .object(JSONObject([
                ("role", .string(role)),
                ("content", .string(text)),
            ]))),
        ]))
    }

    private func blockMessage(_ role: String, blocks: [JSONValue], uuid: String) -> JSONValue {
        .object(JSONObject([
            ("type", .string(role)),
            ("uuid", .string(uuid)),
            ("message", .object(JSONObject([
                ("role", .string(role)),
                ("content", .array(blocks)),
            ]))),
        ]))
    }

    @Test("Plain-string and block content both yield text")
    func extractsBothContentShapes() {
        let blocks: [JSONValue] = [
            .object(JSONObject([("type", .string("text")), ("text", .string("hello from a block"))])),
            .object(JSONObject([("type", .string("tool_use")), ("id", .string("toolu_1"))])),
        ]
        let transcript = Transcript(records: [
            message("user", "plain string content", uuid: "a"),
            blockMessage("assistant", blocks: blocks, uuid: "b"),
        ])
        let messages = ConversationText.messages(in: transcript)
        #expect(messages.count == 2)
        #expect(messages[0].text == "plain string content")
        // The tool_use block carries no prose and must not leak raw JSON into the index.
        #expect(messages[1].text == "hello from a block")
    }

    @Test("Meta records are excluded")
    func skipsMetaRecords() {
        var meta = message("user", "injected harness text", uuid: "m")
        meta["isMeta"] = .bool(true)
        let transcript = Transcript(records: [meta, message("user", "real question", uuid: "r")])
        let messages = ConversationText.messages(in: transcript)
        #expect(messages.count == 1)
        #expect(messages[0].text == "real question")
    }

    @Test("A compaction reads as a marker holding its summary, and a recap as Claude's, not the person's")
    func compactionsAndRecaps() {
        let boundary = JSONValue.object(JSONObject([
            ("type", .string("system")), ("subtype", .string("compact_boundary")), ("uuid", .string("c")),
            ("compactMetadata", .object(JSONObject([("trigger", .string("auto")),
                                                    ("preTokens", .int(180_000)), ("postTokens", .int(12_000))]))),
        ]))
        var summary = message("user", "Earlier we chose five retries.", uuid: "s")
        summary["isCompactSummary"] = .bool(true)
        let recap = JSONValue.object(JSONObject([
            ("type", .string("system")), ("subtype", .string("away_summary")), ("isMeta", .bool(true)),
            ("uuid", .string("r")), ("content", .string("Retries are capped at ten minutes.")),
        ]))
        let readable = ReadableConversation(transcript: Transcript(records: [
            message("user", "Add retries", uuid: "a"), boundary, summary, recap,
            message("assistant", "Done", uuid: "b"),
        ]))
        #expect(readable.messageCount == 2)
        guard readable.entries.count == 4, case .compaction(let compaction) = readable.entries[1],
              case .recap(_, let text, _) = readable.entries[2] else {
            Issue.record("expected message, compaction, recap, message")
            return
        }
        #expect(compaction.summary == "Earlier we chose five retries.")
        #expect(compaction.tokensBefore == 180_000 && compaction.tokensAfter == 12_000)
        #expect(text == "Retries are capped at ten minutes.")
    }
}
