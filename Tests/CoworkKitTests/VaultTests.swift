import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Kept conversations")
struct VaultTests {

    private func claudeCodeConversations() async throws -> [ConversationRef] {
        await Catalog(paths: HostPaths.current).snapshot().conversations.filter { $0.claudeCodeSession != nil }
    }

    @Test("Keeping copies each Claude Code conversation once, and again only when it changes")
    func keepsOnce() async throws {
        try await withSampleAsync { _ in
            let conversations = try await claudeCodeConversations()
            let first = Vault.keep(conversations)
            #expect(first.kept == conversations.filter { !$0.isTranscriptMissing }.count)
            #expect(first.failed.isEmpty)

            let second = Vault.keep(conversations)
            #expect(second.kept == 0)

            // Plus the one the sample Mac already holds, whose original is long gone.
            let entries = Vault.entries()
            #expect(entries.count == first.kept + 1)
            for entry in entries { #expect(Vault.latestCopy(of: entry) != nil) }
        }
    }

    @Test("A conversation that grew replaces its kept copy instead of adding another")
    func growingConversationSupersedes() async throws {
        try await withSampleAsync { _ in
            let conversation = try #require(try await claudeCodeConversations()
                .first { $0.title == "Add a health check endpoint" })
            _ = Vault.keep([conversation])
            let before = try #require(Vault.entries().first { $0.title == "Add a health check endpoint" })
            let oldObject = Vault.objectURL(try #require(before.latest).sha256)

            let url = try #require(conversation.transcriptURL)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one more\"}}\n".utf8))
            try handle.close()

            #expect(Vault.keep([conversation]).kept == 1)
            let after = try #require(Vault.entries().first { $0.title == "Add a health check endpoint" })
            #expect(after.versions.count == 1)
            let newSize = try #require(after.latest).size
            let oldSize = try #require(before.latest).size
            #expect(newSize > oldSize)
            #expect(!FileManager.default.fileExists(atPath: oldObject.path))
        }
    }

    @Test("A kept conversation outlives Claude Code's copy and can be put back, and that can be undone")
    func restoreAfterDeletion() async throws {
        try await withSampleAsync { _ in
            let conversation = try #require(try await claudeCodeConversations()
                .first { $0.title == "Tidy up the thesis bibliography" })
            _ = Vault.keep([conversation])
            let url = try #require(conversation.transcriptURL)
            let original = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)

            let entry = try #require(Vault.entries().first { $0.title == "Tidy up the thesis bibliography" })
            #expect(!entry.sourceExists)
            #expect(try Data(contentsOf: try #require(Vault.latestCopy(of: entry))) == original)

            let receipt = try Vault.restore(entry)
            #expect(receipt.direction == .restore)
            #expect(try Data(contentsOf: url) == original)
            #expect(throws: TransferError.self) { _ = try Vault.restore(entry) }

            _ = try Undo.revertAndRecord(receipt)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(Vault.latestCopy(of: entry) != nil)
        }
    }

    @Test("The sample Mac holds one conversation that exists only as a kept copy")
    func sampleHasOnlyHereEntry() throws {
        try FixtureHomeTests.withSample { _ in
            let entry = try #require(Vault.entries().first { $0.title == "Draft the conference talk abstract" })
            #expect(!entry.sourceExists)
            #expect(Vault.latestCopy(of: entry) != nil)
        }
    }

    @Test("Claude Code's cleanup period is read from its settings, 30 days by default")
    func cleanupPeriod() throws {
        try FixtureHomeTests.withSample { sample in
            #expect(Vault.cleanupPeriod() == 30 * 86_400)
            let settings = sample.paths.claudeCodeConfigDir.appendingPathComponent("settings.json")
            try Data(#"{"cleanupPeriodDays": 90}"#.utf8).write(to: settings)
            #expect(Vault.cleanupPeriod() == 90 * 86_400)
        }
    }

    private func withSampleAsync(_ body: (FixtureHome) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()
        try await HostPaths.$current.withValue(sample.paths) { try await body(sample) }
    }
}
