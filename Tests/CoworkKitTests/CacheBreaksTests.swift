import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Cache breaks")
struct CacheBreaksTests {
    @Test("A reply after the cache expired, that writes the conversation again, is found and priced")
    func breaks() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let url = try #require(conversation.transcriptURL)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func reply(_ id: String, _ at: Date, read: Int, write: Int) -> String {
                #"{"type":"assistant","isSidechain":true,"timestamp":"\#(formatter.string(from: at))","message":{"role":"assistant","model":"claude-opus-5","id":"\#(id)","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\#(write)}},"content":[]}}"#
            }
            let before = sample.now.addingTimeInterval(-3 * 3_600)
            let lines = [reply("msg_before", before, read: 99_000, write: 1_000),
                         reply("msg_after", before.addingTimeInterval(2 * 3_600), read: 0, write: 100_000),
                         reply("msg_soon", before.addingTimeInterval(2 * 3_600 + 60), read: 100_500, write: 500)]
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
            try await index.update(from: snapshot)

            let record = try await FlightRecord.load(conversationID: conversation.id, index: index)
            let marked = record.replies.filter { $0.afterBreak != nil }
            #expect(marked.count == 1)
            #expect((marked.first?.afterBreak ?? 0) > 3_600)

            let summary = try await CacheBreaks.summary(index: index, since: sample.now.addingTimeInterval(-86_400))
            #expect(summary.breaks == 1 && summary.tokens == 100_000)
            // 100K tokens written at twice Opus 5's $5 input price, less the tenth it costs to read them.
            #expect(abs(summary.extra - 0.95) < 0.001)
            #expect(summary.projects.first?.name == "billing-service")
        }
    }
}
