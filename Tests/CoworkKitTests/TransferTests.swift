import Foundation
import Testing

@testable import CoworkKit

@Suite("RewriteEngine")
struct RewriteEngineTests {

    @Test("Longer prefixes win regardless of the order rules are supplied in")
    func longestPrefixFirst() {
        let map = RewriteMap(orderedRules: [(from: "/a", to: "/Y"), (from: "/a/b", to: "/X")])
        #expect(map.apply(to: "/a/b/c").0 == "/X/c")
    }

    @Test("A rule cannot re-match text an earlier rule produced")
    func noCascade() {
        let map = RewriteMap(orderedRules: [(from: "/one", to: "/two"), (from: "/two", to: "/three")])
        #expect(map.apply(to: "/one").0 == "/two")
    }

    @Test("Base64 media payloads are never rewritten")
    func preservesMedia() {
        // The payload deliberately contains the search string; a byte-level substitution
        // would corrupt it, which is why rewriting walks the parsed tree instead.
        let payload = String(repeating: "L3Nlc3Npb25zL29sZA", count: 40)
        var source = JSONObject()
        source["type"] = .string("base64")
        source["media_type"] = .string("image/png")
        source["data"] = .string(payload)
        var block = JSONObject()
        block["type"] = .string("image")
        block["source"] = .object(source)
        var record = JSONObject()
        record["cwd"] = .string("/sessions/old")
        record["content"] = .array([.object(block)])

        let map = RewriteMap(orderedRules: [(from: "/sessions/old", to: "/sessions/new")])
        let (rewritten, stats) = RewriteEngine.apply(map, to: .object(record))

        #expect(rewritten["cwd"]?.stringValue == "/sessions/new")
        #expect(rewritten["content"]?[0]?["source"]?["data"]?.stringValue == payload)
        #expect(stats.skippedMediaFields > 0)
    }

    @Test("Object keys are left alone")
    func doesNotRewriteKeys() {
        var inner = JSONObject()
        inner["/sessions/old/file.txt"] = .string("/sessions/old/file.txt")
        let map = RewriteMap(orderedRules: [(from: "/sessions/old", to: "/sessions/new")])
        let (rewritten, _) = RewriteEngine.apply(map, to: .object(inner))
        #expect(rewritten.objectValue?.has("/sessions/old/file.txt") == true)
        #expect(rewritten["/sessions/old/file.txt"]?.stringValue == "/sessions/new/file.txt")
    }

    @Test("Rewriting twice changes nothing the second time")
    func idempotent() {
        let map = RewriteMap(orderedRules: [(from: "/old", to: "/new")])
        let once = map.apply(to: "/old/x").0
        #expect(map.apply(to: once).0 == once)
    }
}

@Suite("Transcript")
struct TranscriptTests {

    private func record(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(pairs))
    }

    private func minimalChat(uuidA: String = "aaaa", uuidB: String = "bbbb") -> [JSONValue] {
        [
            record([("type", .string("user")), ("uuid", .string(uuidA)), ("parentUuid", .null),
                    ("timestamp", .string("2026-03-11T20:56:15.545Z")),
                    ("message", .object(JSONObject([("role", .string("user")),
                                                    ("content", .string("hello there"))])))]),
            record([("type", .string("assistant")), ("uuid", .string(uuidB)),
                    ("parentUuid", .string(uuidA)),
                    ("timestamp", .string("2026-03-11T20:56:20.000Z")),
                    ("message", .object(JSONObject([("role", .string("assistant")),
                                                    ("content", .string("hi"))])))]),
        ]
    }

    @Test("An intact chain reports no orphans")
    func chainIntegrity() {
        let transcript = Transcript(records: minimalChat())
        let integrity = transcript.chainIntegrity()
        #expect(integrity.orphans.isEmpty)
        #expect(integrity.roots == 1)
    }

    @Test("A missing parent is reported")
    func detectsOrphan() {
        var records = minimalChat()
        records[1]["parentUuid"] = .string("does-not-exist")
        #expect(Transcript(records: records).chainIntegrity().orphans.count == 1)
    }

    @Test("custom-title outranks the first prompt")
    func titlePrecedence() {
        var records = minimalChat()
        records.append(record([("type", .string("custom-title")),
                               ("customTitle", .string("Chosen Title"))]))
        let (title, source) = Transcript(records: records).resolvedTitle()
        #expect(title == "Chosen Title")
        #expect(source == .customTitle)
    }

    @Test("Without any title record the first user message is used")
    func titleFallsBackToFirstPrompt() {
        let (title, _) = Transcript(records: minimalChat()).resolvedTitle()
        #expect(title.contains("hello there"))
    }

    @Test("Tokens that hide a session from the resume picker are detected")
    func detectsPickerFilters() {
        // These four make Claude Code drop the session from the picker silently. They can
        // arrive as literal text inside a tool result that once printed another transcript,
        // so detection works on the serialized bytes rather than on field lookups.
        for token in [#""isSidechain":true"#, #""teamName""#, #""sessionKind""#,
                      #""entrypoint":"sdk-cli""#] {
            var records = minimalChat()
            records[0]["message"] = .object(JSONObject([
                ("role", .string("user")),
                ("content", .string("tool output was: \(token) and then more")),
            ]))
            let violations = Transcript(records: records).pickerFilterViolations()
            #expect(!violations.isEmpty, "failed to detect \(token)")
        }
    }

    @Test("A clean transcript reports no picker violations")
    func cleanTranscriptPasses() {
        #expect(Transcript(records: minimalChat()).pickerFilterViolations().isEmpty)
    }

    @Test("Records survive a write/read round trip byte-for-byte")
    func roundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Transcript(records: minimalChat())
        let url = root.appendingPathComponent("t.jsonl")
        try original.write(to: url)
        let reloaded = try Transcript(contentsOf: url)

        #expect(reloaded.records.count == original.records.count)
        #expect(reloaded.contentFingerprints() == original.contentFingerprints())
    }
}

@Suite("JSONValue")
struct JSONValueTests {

    @Test("Unknown keys and key order survive a parse/serialize round trip")
    func preservesUnknownKeysAndOrder() throws {
        // The whole reason this type exists: session metadata accretes fields over time, and
        // a Codable model would silently drop the ones it does not know about.
        let source = #"{"zeta":1,"alpha":{"nested":[1,2,{"deep":true}]},"future_field":"keep me"}"#
        let parsed = try JSONValue.parse(source)
        let output = String(decoding: parsed.serialized(), as: UTF8.self)
        #expect(output == source)
    }

    @Test("Millisecond timestamps do not lose precision")
    func preservesLargeIntegers() throws {
        let parsed = try JSONValue.parse(#"{"createdAt":1774888596462}"#)
        #expect(parsed["createdAt"]?.intValue == 1_774_888_596_462)
        #expect(String(decoding: parsed.serialized(), as: UTF8.self) == #"{"createdAt":1774888596462}"#)
    }

    @Test("Escapes and surrogate pairs round trip")
    func handlesEscapes() throws {
        let parsed = try JSONValue.parse(#"{"s":"line\nbreak \"quoted\" é 😀"}"#)
        #expect(parsed["s"]?.stringValue == "line\nbreak \"quoted\" é 😀")
        let reparsed = try JSONValue.parse(parsed.serialized())
        #expect(reparsed["s"]?.stringValue == parsed["s"]?.stringValue)
    }
}
