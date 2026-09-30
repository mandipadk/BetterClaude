import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Conversation page")
struct ConversationPageTests {
    @Test("A conversation becomes one page with no scripts, keys hidden and the home folder shortened")
    func page() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, _ in
            let conversation = try #require(snapshot.conversations.first { $0.title == "Add a health check endpoint" })
            let readable = ReadableConversation(transcript: try Transcript(contentsOf: try #require(conversation.transcriptURL)))
            let html = ConversationPage.render(readable, title: conversation.title, model: "Opus 5.5",
                                               home: sample.paths.home.path)
            #expect(html.hasPrefix("<!doctype html>"))
            #expect(!html.lowercased().contains("<script"))
            #expect(!html.contains("http://") && !html.contains("src="))
            #expect(!html.contains(FixtureHome.sampleKeys.anthropic))
            #expect(html.contains("[anthropic api key hidden]"))
            #expect(!html.contains(sample.paths.home.path))
            #expect(html.contains("<h2>You"))
            if let out = ProcessInfo.processInfo.environment["BC_PAGE_OUT"] { try html.write(toFile: out, atomically: true, encoding: .utf8) }
        }
    }

    @Test("Markdown becomes safe HTML")
    func markdown() {
        let html = ConversationPage.markdown("# Plan\n\n- one `x<y`\n- **two**\n\n```swift\nlet a = \"<b>\"\n```\nSee [docs](https://example.com) or [bad](javascript:alert(1))")
        #expect(html.contains("<h3>Plan</h3>"))
        #expect(html.contains("<li>one <code>x&lt;y</code></li>"))
        #expect(html.contains("<strong>two</strong>"))
        #expect(html.contains("<pre><code>let a = &quot;&lt;b&gt;&quot;</code></pre>"))
        #expect(html.contains("<a href=\"https://example.com\">docs</a>"))
        #expect(!html.contains("href=\"javascript"))
    }
}
