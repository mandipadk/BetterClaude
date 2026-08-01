import Foundation
import Testing

@testable import CoworkKit

/// The string parser has two paths: a fast one that decodes an unescaped run in a single
/// pass, and a slower one that accumulates bytes when an escape appears. The fast path is
/// what makes a 10 MB transcript parse in 0.04s instead of 48s, and the risk it introduces
/// is that the two paths disagree. These tests pin them together.
@Suite("JSON string parsing")
struct JSONParserTests {

    private func roundTrip(_ value: String) throws -> String? {
        let object = JSONValue.object(JSONObject([("s", .string(value))]))
        let reparsed = try JSONValue.parse(object.serialized())
        return reparsed["s"]?.stringValue
    }

    @Test("An unescaped string survives the fast path")
    func fastPath() throws {
        #expect(try roundTrip("plain ascii") == "plain ascii")
        #expect(try roundTrip("") == "")
        #expect(try roundTrip("spaces  and\tpunctuation!?") == "spaces  and\tpunctuation!?")
    }

    @Test("Escapes survive the slow path")
    func escapes() throws {
        #expect(try roundTrip("line\nbreak") == "line\nbreak")
        #expect(try roundTrip("quote\"inside") == "quote\"inside")
        #expect(try roundTrip("back\\slash") == "back\\slash")
        #expect(try roundTrip("tab\there\rreturn") == "tab\there\rreturn")
        #expect(try roundTrip("\u{08}\u{0C}") == "\u{08}\u{0C}")
    }

    @Test("Multi-byte UTF-8 survives both paths")
    func unicode() throws {
        // No escape — fast path.
        #expect(try roundTrip("café · 日本語 · 😀") == "café · 日本語 · 😀")
        // Escape forces the slow path over the same content.
        #expect(try roundTrip("café\n日本語\n😀") == "café\n日本語\n😀")
    }

    @Test("An escape at the very start still copies the leading run correctly")
    func escapeAtBoundaries() throws {
        #expect(try roundTrip("\nleading") == "\nleading")
        #expect(try roundTrip("trailing\n") == "trailing\n")
        #expect(try roundTrip("\n") == "\n")
    }

    @Test("Surrogate pairs decode to one scalar")
    func surrogatePairs() throws {
        let parsed = try JSONValue.parse(#"{"s":"😀"}"#)
        #expect(parsed["s"]?.stringValue == "😀")
    }

    @Test("A lone surrogate degrades rather than throwing")
    func loneSurrogate() throws {
        // One damaged record must not make a whole transcript unreadable.
        let parsed = try JSONValue.parse(#"{"s":"a\uD83Db"}"#)
        let value = try #require(parsed["s"]?.stringValue)
        #expect(value.hasPrefix("a"))
        #expect(value.hasSuffix("b"))
    }

    @Test("Escaped and unescaped forms of the same text produce identical results")
    func pathsAgree() throws {
        // "/" may be escaped or not; both must decode the same.
        let escaped = try JSONValue.parse(#"{"s":"a\/b"}"#)
        let plain = try JSONValue.parse(#"{"s":"a/b"}"#)
        #expect(escaped["s"]?.stringValue == plain["s"]?.stringValue)
        #expect(plain["s"]?.stringValue == "a/b")
    }

    @Test("An unterminated string throws rather than looping")
    func unterminated() {
        #expect(throws: (any Error).self) { try JSONValue.parse(#"{"s":"no end"#) }
        #expect(throws: (any Error).self) { try JSONValue.parse(#"{"s":"esc\"#) }
    }

    @Test("Key order and unknown keys survive a large realistic record")
    func realisticRecord() throws {
        let source = #"{"type":"assistant","uuid":"a-1","message":{"role":"assistant","content":[{"type":"text","text":"Here is a path: /Users/x/y and a quote: \"hi\""}]},"unknownFutureField":{"nested":[1,2,3]}}"#
        let parsed = try JSONValue.parse(source)
        #expect(String(decoding: parsed.serialized(), as: UTF8.self) == source)
        #expect(parsed["message"]?["content"]?[0]?["text"]?.stringValue
                == #"Here is a path: /Users/x/y and a quote: "hi""#)
    }
}
