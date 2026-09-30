import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Decisions")
struct DecisionsTests {
    @Test("Decisions come from what you said and Claude's summaries, not from Claude narrating its steps")
    func sentences() {
        #expect(Decisions.sentences(in: "Sounds good. Let's go with Postgres for this.", role: "user", kind: "message").map(\.0)
                == ["Let's go with Postgres for this."])
        #expect(Decisions.sentences(in: "I decided to check the logs first.", role: "assistant", kind: "message").isEmpty)
        #expect(Decisions.sentences(in: "We agreed to cap retries at five.", role: "assistant", kind: "message").count == 1)
        #expect(Decisions.sentences(in: "Should we go with Redis?", role: "user", kind: "message").isEmpty)
        #expect(Decisions.sentences(in: "- Chose SQLite over Core Data for the index.", role: "user", kind: "compaction").first?.1 == .summary)
    }

    @Test("A project's decisions list who decided and where, and a dismissed one stays gone")
    func list() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let billing = sample.paths.home.appendingPathComponent("Code/billing-service").path
            let decisions = try await Decisions.list(index: index, project: billing, paths: sample.paths)
            let cap = try #require(decisions.first { $0.text.contains("ten minute cap") })
            #expect(cap.source == .you && cap.conversationTitle == "Retry failed webhook deliveries with backoff")

            let all = try await Decisions.list(index: index, topic: "picker flag", paths: sample.paths)
            #expect(all.contains { $0.source == .summary && $0.text.hasPrefix("Decided to keep the old picker") })

            try DismissedDecisions.dismiss(cap.id, paths: sample.paths)
            #expect(try await Decisions.list(index: index, project: billing, paths: sample.paths).allSatisfy { $0.id != cap.id })

            let recall = Recall(index: index, accounts: [RecallTests.personal])
            #expect(try await recall.decisions(project: nil, topic: "picker").contains("Decided to keep the old picker"))
        }
    }
}
