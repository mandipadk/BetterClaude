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
            #expect(!created.frames[0].isMissing && !created.frames.contains(where: \.changedSince))
        }
    }

    @Test("A version whose copy is gone reads as not kept, not as an empty file")
    func missingVersion() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let deliver = try #require(try await Timelapse.files(conversationID: conversation.id, index: index).first { $0.hasSuffix("deliver.ts") })
            let row = try #require(try await index.rows(
                "SELECT backup_file FROM file_versions WHERE conversation_id = ? AND file_path = ? ORDER BY version LIMIT 1",
                [.text(conversation.id), .text(deliver)]).first)
            let backup = try #require(row.text(0))
            let copy = try #require(FileProvenance.locate(backup: backup, session: conversation.cliSessionId,
                                                          transcript: conversation.transcriptURL?.path, paths: sample.paths))
            try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: copy)

            let timelapse = try await Timelapse.load(conversationID: conversation.id, path: deliver, index: index, paths: sample.paths)
            #expect(timelapse.frames[0].isMissing && timelapse.frames[0].text == nil)
            #expect(timelapse.change(into: 1) == nil)
            #expect(timelapse.change(into: 2) != nil)
        }
    }

    @Test("The file as it is now isn't credited to the last prompt once it changed after the conversation")
    func changedAfterwards() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let deliver = try #require(try await Timelapse.files(conversationID: conversation.id, index: index).first { $0.hasSuffix("deliver.ts") })
            try Data((FixtureHome.deliverNow + "\n// edited by hand\n").utf8).write(to: URL(fileURLWithPath: deliver))

            let timelapse = try await Timelapse.load(conversationID: conversation.id, path: deliver, index: index, paths: sample.paths)
            let now = try #require(timelapse.frames.last)
            #expect(now.changedSince && now.prompt == nil)
        }
    }
}
