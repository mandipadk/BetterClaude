import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Claims")
struct ClaimsTests {
    @Test("Claims are read from what was said, and plans aren't claims")
    func reading() {
        #expect(Claims.claims(in: "Done. All tests pass.").map(\.1) == [.testsPass])
        #expect(Claims.claims(in: "I updated deliver.ts to retry.").first?.2 == "deliver.ts")
        #expect(Claims.claims(in: "Once the tests pass I'll update deliver.ts.").isEmpty)
        #expect(Claims.claims(in: "Upgraded to version 2.1.0 today.").isEmpty)
        #expect(Claims.claims(in: "Committed and pushed to main.").map(\.1) == [.committed, .pushed])
    }

    @Test("A sub-agent's report is checked against what it did: backed, contradicted, or with no evidence")
    func verdicts() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let claims = try await Claims.check(conversationID: conversation.id, index: index)
            let unbacked = try #require(claims.first { $0.agentID == "a1f0search" && $0.kind == .edited })
            #expect(unbacked.verdict == .noEvidence)
            let tests = try #require(claims.first { $0.agentID == "b2e1tests" && $0.kind == .testsPass })
            #expect(tests.verdict == .contradicted("the last run, pnpm test backoff, failed"))
            let wrote = try #require(claims.first { $0.agentID == "b2e1tests" && $0.kind == .edited })
            #expect(wrote.verdict == .backed("1 edit to backoff.test.ts"))
        }
    }
}
