import Foundation
import Testing

@testable import CoworkKit

@Suite("Search")
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

    private func entry(title: String, records: [JSONValue],
                       lastActivity: Date = .now) throws -> SearchIndex.Entry {
        let transcript = Transcript(records: records)
        let messages = ConversationText.messages(in: transcript)
        let haystack = (title + "\n" + messages.map(\.text).joined(separator: "\n")).lowercased()
        return SearchIndex.Entry(
            location: ConversationLocation(kind: .cowork, container: "Claude", identity: "me",
                                           transcriptURL: URL(fileURLWithPath: "/tmp/x.jsonl"),
                                           rowID: title),
            title: title, lastActivity: lastActivity, messages: messages, haystack: haystack)
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

    @Test("All terms must appear — search is AND, not OR")
    func requiresEveryTerm() async throws {
        let index = SearchIndex()
        await index.replaceAll(with: [
            try entry(title: "Alpha", records: [message("user", "postgres migration plan", uuid: "1")]),
            try entry(title: "Beta", records: [message("user", "postgres backup only", uuid: "2")]),
        ])
        let both = await index.search("postgres migration")
        #expect(both.count == 1)
        #expect(both[0].conversationTitle == "Alpha")

        let one = await index.search("postgres")
        #expect(one.count == 2)
    }

    @Test("A title match outranks a body match")
    func titleOutranksBody() async throws {
        let index = SearchIndex()
        await index.replaceAll(with: [
            try entry(title: "Unrelated", records: [
                message("user", "kubernetes kubernetes kubernetes kubernetes", uuid: "1"),
            ]),
            try entry(title: "Kubernetes rollout", records: [message("user", "one mention", uuid: "2")]),
        ])
        let hits = await index.search("kubernetes")
        #expect(hits.first?.conversationTitle == "Kubernetes rollout")
    }

    @Test("Excerpts are trimmed around the match and marked as elided")
    func excerptsAreWindowed() async throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 40)
        let index = SearchIndex()
        await index.replaceAll(with: [
            try entry(title: "Long", records: [message("user", filler + "NEEDLE " + filler, uuid: "1")]),
        ])
        let hits = await index.search("needle")
        let excerpt = try #require(hits.first?.excerpts.first)
        #expect(excerpt.text.count < 250, "excerpt should be a window, not the whole message")
        #expect(excerpt.text.contains("NEEDLE"))
        #expect(excerpt.text.hasPrefix("…"))
        #expect(excerpt.text.hasSuffix("…"))
        #expect(!excerpt.ranges.isEmpty, "the match should be locatable for highlighting")
    }

    @Test("An empty query returns nothing rather than everything")
    func emptyQueryIsEmpty() async throws {
        let index = SearchIndex()
        await index.replaceAll(with: [try entry(title: "A", records: [message("user", "x", uuid: "1")])])
        #expect(await index.search("").isEmpty)
        #expect(await index.search("   ").isEmpty)
    }

    @Test("Search is case-insensitive")
    func caseInsensitive() async throws {
        let index = SearchIndex()
        await index.replaceAll(with: [
            try entry(title: "Casing", records: [message("user", "The Quick Brown Fox", uuid: "1")]),
        ])
        #expect(await index.search("quick brown").count == 1)
        #expect(await index.search("QUICK BROWN").count == 1)
    }
}
