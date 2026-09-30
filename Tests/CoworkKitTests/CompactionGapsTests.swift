import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("What compaction forgot")
struct CompactionGapsTests {
    @Test("An instruction the summary no longer mentions is found; one it kept isn't")
    func gaps() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Migrate the date picker to the new API" })
            let gaps = try await CompactionGaps.gaps(conversationID: conversation.id, index: index)
            let first = try #require(gaps.first)
            #expect(first.forgotten.map(\.text) == ["Don't change the date format in exported CSVs, finance parses them."])
            #expect(first.checked >= 2)
        }
    }

    @Test("Instructions are the sentences meant to outlast the turn")
    func instructions() {
        let found = CompactionGaps.instructions(in: "Looks good. Always run the linter before committing. What's next?")
        #expect(found.map(\.0) == ["Always run the linter before committing."])
        #expect(CompactionGaps.instructions(in: "Thanks, that works.").isEmpty)
    }
}
