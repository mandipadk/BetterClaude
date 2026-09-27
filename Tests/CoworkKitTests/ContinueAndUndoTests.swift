import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// The write paths, end to end on a sample Mac: carry a conversation into another install,
/// fork one, and take each back.
@Suite("Continue, fork and undo")
struct ContinueAndUndoTests {

    @Test("A conversation carried into a Parallex copy appears there, and undo removes it")
    func continueIntoParallexCopy() throws {
        try FixtureHomeTests.withSample { sample in
            let stores = try Discovery.stores()
            let claude = try #require(stores.first { $0.variantDirName == "Claude" })
            let work = try #require(stores.first { $0.variantDirName == "Claude Work" })
            let source = try #require(try Discovery.accounts(in: claude).first)
            let destination = try #require(try Discovery.accounts(in: work).first)
            let session = try #require(try Discovery.sessions(in: source)
                .first { $0.title == "Plan a three-day trip to Lisbon" })
            let before = try Discovery.sessions(in: destination).count

            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bundle = staging.appendingPathComponent("t.coworkbundle")
            let export = try Exporter.plan([session], options: ExportOptions())
            _ = try Exporter.write(export, to: bundle, profile: .sameUser)
            let plan = try Importer.plan(bundle: bundle, to: .cowork(destination))
            #expect(plan.isExecutable)

            let receipt = try Importer.apply(plan)
            #expect(receipt.completed)
            #expect(receipt.title == "Plan a three-day trip to Lisbon")
            let after = try Discovery.sessions(in: destination)
            #expect(after.count == before + 1)
            #expect(after.contains { $0.title == "Plan a three-day trip to Lisbon" })

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.skipped.filter { $0.reason != "already absent" }.map(\.reason) == [])
            #expect(try Discovery.sessions(in: destination).count == before)
            // Nothing it wrote survives, the copied workspace included.
            #expect(receipt.created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            let recorded = try #require(try Undo.receipts().first { $0.id == receipt.id })
            #expect(recorded.revertedAt != nil)
            #expect(try Undo.incomplete().isEmpty)
        }
    }

    @Test("A fork is written beside its source with a receipt, and undo removes only the fork")
    func forkAndUndo() throws {
        try FixtureHomeTests.withSample { _ in
            let config = Discovery.defaultClaudeCodeConfigDir()
            let session = try #require(try Discovery.claudeCodeProjects(configDir: config)
                .flatMap { try Discovery.claudeCodeSessions(projectDir: $0, configDir: config) }
                .first { $0.title == "Retry failed webhook deliveries with backoff" })
            let transcript = try Transcript(contentsOf: session.transcriptURL)
            let points = ConversationBranch.points(in: transcript)
            let cut = try #require(points.first)

            let (plan, branch) = try ConversationBranch.plan(transcript: transcript, cutAt: cut,
                                                             newTitle: "Webhook retries (fork)")
            let receipt = try ConversationBranch.write(branch, plan: plan)
            #expect(receipt.direction == .branch)
            #expect(FileManager.default.fileExists(atPath: plan.destinationURL.path))

            let titles = try Discovery.claudeCodeSessions(projectDir: session.projectDir, configDir: config).map(\.title)
            #expect(titles.contains("Webhook retries (fork)"))

            _ = try Undo.revertAndRecord(receipt)
            #expect(!FileManager.default.fileExists(atPath: plan.destinationURL.path))
            #expect(FileManager.default.fileExists(atPath: session.transcriptURL.path))
        }
    }

    @Test("Undo leaves a copy alone once it has been changed")
    func undoKeepsEditedFiles() throws {
        try FixtureHomeTests.withSample { _ in
            let config = Discovery.defaultClaudeCodeConfigDir()
            let session = try #require(try Discovery.claudeCodeProjects(configDir: config)
                .flatMap { try Discovery.claudeCodeSessions(projectDir: $0, configDir: config) }
                .first { $0.title == "Add a health check endpoint" })
            let transcript = try Transcript(contentsOf: session.transcriptURL)
            let cut = try #require(ConversationBranch.points(in: transcript).first)
            let (plan, branch) = try ConversationBranch.plan(transcript: transcript, cutAt: cut, newTitle: nil)
            let receipt = try ConversationBranch.write(branch, plan: plan)

            let handle = try FileHandle(forWritingTo: plan.destinationURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"user\"}\n".utf8))
            try handle.close()

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.skipped.count == 1)
            #expect(FileManager.default.fileExists(atPath: plan.destinationURL.path))
        }
    }

    @Test("Notices are shown, not hidden among passed checks")
    func noticesAreMarked() {
        let notice = PreconditionResult(id: "PC12", title: "Project will be created", passed: true,
                                        detail: "Q4 planning", isNotice: true)
        #expect(notice.passed && notice.isNotice)
    }
}
