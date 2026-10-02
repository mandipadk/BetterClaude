import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// Codex writes a session file for every thread, and most aren't a conversation a person had.
@Suite("Codex sessions")
struct CodexSessionTests {

    @Test("Only conversations a person had are listed; sub-agents, reviews and other programs' runs are counted apart")
    func onlyConversations() throws {
        try FixtureHomeTests.withSample { _ in
            let listed = CodexSessions.conversations()
            #expect(listed.map(\.id) == ["0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"])
            #expect(listed.first?.title == "Refunds post twice on webhook retry")

            let survey = CodexSessions.survey()
            #expect(survey.counts[.conversation] == 1)
            #expect(survey.counts[.subagent] == 1)
            #expect(survey.counts[.review] == 1)
            #expect(survey.automatedBy == ["nightly-bot": 1])
        }
    }

    @Test("A fork is read by its own header, not the parent's copy further down")
    func forkKeepsItsOwnID() throws {
        try FixtureHomeTests.withSample { _ in
            let files = CodexSessions.sessionFiles(paths: .current)
            let fork = try #require(files.first { $0.lastPathComponent.contains("4a60") })
            let head = try #require(CodexSessions.headOf(fork))
            #expect(head.id == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a60")
            #expect(head.kind == .subagent)
        }
    }

    @Test("The catalog never lists one conversation twice")
    func uniqueIDs() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, _ in
            #expect(Set(snapshot.conversations.map(\.id)).count == snapshot.conversations.count)
        }
    }
}
