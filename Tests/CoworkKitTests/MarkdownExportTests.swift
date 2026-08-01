import Foundation
import Testing

@testable import CoworkKit

@Suite("MarkdownExport")
struct MarkdownExportTests {

    private func transcript() -> Transcript {
        Transcript(records: [
            .object(JSONObject([
                ("type", .string("user")), ("uuid", .string("a")),
                ("timestamp", .string("2026-03-11T20:56:15.545Z")),
                ("message", .object(JSONObject([
                    ("role", .string("user")), ("content", .string("How do I reverse a list?")),
                ]))),
            ])),
            .object(JSONObject([
                ("type", .string("assistant")), ("uuid", .string("b")),
                ("parentUuid", .string("a")),
                ("timestamp", .string("2026-03-11T20:56:20.000Z")),
                ("message", .object(JSONObject([
                    ("role", .string("assistant")),
                    ("content", .array([
                        .object(JSONObject([("type", .string("text")),
                                            ("text", .string("Use `reversed()`."))])),
                        .object(JSONObject([("type", .string("tool_use")),
                                            ("id", .string("toolu_1"))])),
                    ])),
                ]))),
            ])),
        ])
    }

    @Test("Both speakers appear, in order")
    func rendersConversation() {
        let out = MarkdownExport.render(transcript: transcript(), title: "Reversing a list")
        #expect(out.contains("# Reversing a list"))
        #expect(out.contains("## You"))
        #expect(out.contains("How do I reverse a list?"))
        #expect(out.contains("## Claude"))
        #expect(out.contains("Use `reversed()`."))
        let you = try? #require(out.range(of: "## You"))
        let claude = try? #require(out.range(of: "## Claude"))
        if let you, let claude { #expect(you.lowerBound < claude.lowerBound) }
    }

    @Test("Tool plumbing does not leak into the document")
    func omitsToolNoise() {
        let out = MarkdownExport.render(transcript: transcript(), title: "T")
        #expect(!out.contains("toolu_1"))
        #expect(!out.contains("tool_use"))
    }

    @Test("Front matter can be suppressed for a quick paste")
    func frontMatterOptional() {
        let bare = MarkdownExport.render(transcript: transcript(), title: "T",
                                         options: .init(includeFrontMatter: false))
        #expect(!bare.contains("# T"))
        #expect(bare.hasPrefix("## You"))
    }

    @Test("Filenames stay safe and recognisable")
    func fileNames() {
        #expect(MarkdownExport.suggestedFileName(for: "Q3/Q4: plan") == "Q3-Q4- plan.md")
        #expect(MarkdownExport.suggestedFileName(for: "   ") == "conversation.md")
        #expect(MarkdownExport.suggestedFileName(for: String(repeating: "x", count: 200)).count <= 83)
    }
}
