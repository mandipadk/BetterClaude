import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Model drift")
struct ModelDriftTests {
    @Test("A change of model nobody asked for is told apart from one you asked for with /model")
    func switches() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Migrate the date picker to the new API" })
            let changes = try await ModelDrift.switches(conversationID: conversation.id, index: index)
            #expect(changes.count == 2)
            #expect(changes[0].from == "claude-sonnet-5" && changes[0].to == "claude-opus-4-8" && changes[0].cause == .unexplained)
            #expect(changes[0].replies == 22)
            #expect(changes[1].to == "claude-sonnet-5" && changes[1].cause == .requested)

            let unexplained = try await ModelDrift.unexplained(index: index, since: sample.now.addingTimeInterval(-30 * 86_400))
            #expect(unexplained.map(\.title) == ["Migrate the date picker to the new API"])

            let webhook = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let helper = try #require(try await Subagents.runs(conversationID: webhook.id, index: index).first { $0.agentID == "c3d2helper" })
            #expect(helper.requestedModel == "opus" && helper.ranOnOtherModel)
        }
    }
}
