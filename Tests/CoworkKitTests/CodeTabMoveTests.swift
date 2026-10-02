import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// A Claude Code conversation carries on in a Claude Desktop's Code tab, never as a Cowork task.
@Suite("Moving a Claude Code conversation to a Code tab")
struct CodeTabMoveTests {

    private func cliConversation() throws -> CCSessionRef {
        let config = Discovery.defaultClaudeCodeConfigDir()
        return try #require(try Discovery.claudeCodeProjects(configDir: config)
            .flatMap { try Discovery.claudeCodeSessions(projectDir: $0, configDir: config) }
            .first { $0.title == "Add a health check endpoint" })
    }

    @Test("It's listed in the Code tab as the same conversation, nothing copied, and Undo takes the listing back")
    func sameConfigFolder() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, _ in
            let claude = try #require(snapshot.installs.first { $0.name == "Claude" })
            let root = try #require(claude.codeTabRoot)
            let session = try cliConversation()
            let config = Discovery.defaultClaudeCodeConfigDir()
            let before = CodeTabSessions.sessions(in: root).count

            let plan = CodeTabMove.plan(title: session.title, cliSessionId: session.sessionId, cwd: session.resolvedCwd,
                                        transcript: session.transcriptURL, lastActivity: session.lastTimestamp,
                                        sourceRecord: nil, codeTabRoot: root,
                                        destinationConfigDir: config, sourceConfigDir: config)
            #expect(plan.isExecutable, "\(plan.problems)")
            #expect(plan.copyTo == nil, "the Code tab reads the same Claude Code folder; nothing to copy")
            let receipt = try CodeTabMove.apply(plan, destinationName: "Claude")
            #expect(receipt.direction == .codeTab)

            let records = CodeTabSessions.sessions(in: root)
            #expect(records.count == before + 1)
            #expect(records.contains { $0.cliSessionId == session.sessionId && $0.cwd == session.resolvedCwd })
            // The catalog now lists it in Claude's Code tab, claiming the same transcript.
            let after = await Catalog(paths: snapshot.paths).snapshot()
            let listed = after.conversations.filter { $0.cliSessionId == session.sessionId }
            #expect(listed.count == 1)
            #expect(listed.first?.installID == claude.id)

            let again = CodeTabMove.plan(title: session.title, cliSessionId: session.sessionId, cwd: session.resolvedCwd,
                                         transcript: session.transcriptURL, lastActivity: nil, sourceRecord: nil,
                                         codeTabRoot: root, destinationConfigDir: config, sourceConfigDir: config)
            #expect(!again.isExecutable, "a second move is refused")

            _ = try Undo.revertAndRecord(receipt)
            #expect(CodeTabSessions.sessions(in: root).count == before)
            #expect(FileManager.default.fileExists(atPath: session.transcriptURL.path), "the conversation itself is never touched")
        }
    }

    @Test("A Claude with a Claude Code folder of its own gets the transcript copied there")
    func separateConfigFolder() throws {
        try FixtureHomeTests.withSample { sample in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let root = try #require(claude.codeTabRoot)
            let session = try cliConversation()
            let own = sample.root.appendingPathComponent("own-claude-code", isDirectory: true)
            let plan = CodeTabMove.plan(title: session.title, cliSessionId: session.sessionId, cwd: session.resolvedCwd,
                                        transcript: session.transcriptURL, lastActivity: nil, sourceRecord: nil,
                                        codeTabRoot: root, destinationConfigDir: own,
                                        sourceConfigDir: Discovery.defaultClaudeCodeConfigDir())
            #expect(plan.isExecutable, "\(plan.problems)")
            let copy = try #require(plan.copyTo)
            #expect(copy.path.hasPrefix(own.path))
            _ = try CodeTabMove.apply(plan, destinationName: "Claude")
            #expect(FileManager.default.fileExists(atPath: copy.path))
        }
    }
}
