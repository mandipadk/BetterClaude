import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Sub-agents")
struct SubagentsTests {
    @Test("A conversation's sub-agents are indexed under it: their runs, their tree, and their cost in every total")
    func indexed() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })

            let runs = try await Subagents.runs(conversationID: conversation.id, index: index)
            #expect(runs.count == 4)
            // The test writer is followed by the searcher it spawned.
            let tests = try #require(runs.firstIndex { $0.agentID == "b2e1tests" })
            #expect(runs[tests + 1].agentID == "c3d2helper" && runs[tests + 1].depth == 2)
            #expect(runs[tests].type == "general-purpose" && runs[tests].tools == 3 && runs[tests].cost > 0)
            let older = try #require(runs.first { $0.agentID == "d4e3older" })
            #expect(older.result == nil && older.type == nil && older.title.hasPrefix("Check whether the dead-letter"))

            // Their usage counts toward the conversation, but not toward its own context.
            let record = try await FlightRecord.load(conversationID: conversation.id, index: index)
            #expect(record.agents == 4 && record.agentCost > 0)
            #expect(record.replies.allSatisfy { !$0.model.isEmpty } && record.totalCost > record.agentCost)
            let counted = try await index.rows("SELECT COUNT(*) FROM usage WHERE conversation_id = ? AND agent_id IS NOT NULL", [.text(conversation.id)])
            #expect(counted.first?.int(0) == 10)
            // A sub-agent's edits are the conversation's too.
            let changes = try await ConversationRewind.changes(conversationID: conversation.id, index: index, paths: sample.paths)
            #expect(changes.files.contains { $0.path.hasSuffix("backoff.test.ts") })

            // Rescanning the conversation keeps its sub-agents' rows; an unchanged sub-agent isn't read again.
            try await index.update(from: snapshot)
            let again = try await index.rows("SELECT COUNT(*) FROM usage WHERE conversation_id = ? AND agent_id IS NOT NULL", [.text(conversation.id)])
            #expect(again.first?.int(0) == 10)
        }
    }
}
