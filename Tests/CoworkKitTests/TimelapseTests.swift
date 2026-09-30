import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Time-lapse")
struct TimelapseTests {
    @Test("A file plays back from before the conversation, through each saved version, to now, with what was asked")
    func frames() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let files = try await Timelapse.files(conversationID: conversation.id, index: index)
            let deliver = try #require(files.first { $0.hasSuffix("deliver.ts") })
            let timelapse = try await Timelapse.load(conversationID: conversation.id, path: deliver, index: index, paths: sample.paths)
            #expect(timelapse.frames.map(\.text) == [FixtureHome.deliverBefore, FixtureHome.deliverMiddle, FixtureHome.deliverNow])
            #expect(timelapse.frames[0].prompt == nil)
            #expect(timelapse.frames[2].prompt == "Can we cap the total wait at ten minutes?")
            #expect((timelapse.change(into: 2)?.added ?? 0) > 0)

            let backoff = try #require(files.first { $0.hasSuffix("backoff.ts") })
            let created = try await Timelapse.load(conversationID: conversation.id, path: backoff, index: index, paths: sample.paths)
            #expect(created.frames.first?.text == nil && created.frames.last?.text == FixtureHome.backoffNow)
        }
    }
}
