import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Provenance")
struct ProvenanceTests {

    static func files(_ sample: FixtureHome) -> (deliver: String, backoff: String) {
        let folder = sample.paths.home.appendingPathComponent("Code/billing-service/src/webhooks")
        return (folder.appendingPathComponent("deliver.ts").path, folder.appendingPathComponent("backoff.ts").path)
    }

    @Test("A file's history names the conversations that touched it and the versions saved before each change")
    func history() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let (deliver, backoff) = Self.files(sample)

            let recent = try await FileProvenance.recentFiles(index: index)
            #expect(recent.contains { $0.path == deliver })
            #expect(try await FileProvenance.recentFiles(index: index, matching: "backoff").map(\.path) == [backoff])

            let history = try await FileProvenance.history(of: deliver, index: index, paths: sample.paths)
            #expect(history.versions.count == 1)
            #expect(history.versions.first?.copy != nil)
            #expect(history.versions.first?.conversationTitle == "Retry failed webhook deliveries with backoff")
            #expect(history.conversations.first?.tools.contains("Edit") == true)
            #expect(!history.createdByClaude)

            #expect(try await FileProvenance.history(of: backoff, index: index, paths: sample.paths).createdByClaude)
        }
    }

    @Test("Restoring a version saves what's there first, and Undo puts it back")
    func restoreAndUndo() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let (deliver, backoff) = Self.files(sample)
            let before = try #require(try await FileProvenance.history(of: deliver, index: index, paths: sample.paths).versions.first)

            let receipt = try FileProvenance.restore(before, to: deliver, paths: sample.paths)
            #expect(try String(contentsOfFile: deliver, encoding: .utf8) == FixtureHome.deliverBefore)
            _ = try Undo.revert(receipt)
            #expect(try String(contentsOfFile: deliver, encoding: .utf8) == FixtureHome.deliverNow)

            // Going back to before Claude created a file takes it away, and Undo brings it back.
            let created = try #require(try await FileProvenance.history(of: backoff, index: index, paths: sample.paths).versions.first)
            let removal = try FileProvenance.restore(created, to: backoff, paths: sample.paths)
            #expect(!FileManager.default.fileExists(atPath: backoff))
            _ = try Undo.revert(removal)
            #expect(try String(contentsOfFile: backoff, encoding: .utf8) == FixtureHome.backoffNow)
        }
    }

    @Test("Saved versions and plans are kept, and still found after Claude Code's cleanup deletes them")
    func keepsVersions() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let config = sample.paths.claudeCodeConfigDir
            let plans = config.appendingPathComponent("plans", isDirectory: true)
            try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
            try Data("# Plan\n".utf8).write(to: plans.appendingPathComponent("retry-plan.md"))

            let report = KeptFileHistory.keep(configDirs: [config], paths: sample.paths)
            #expect(report.copied == 2)
            #expect(KeptFileHistory.keep(configDirs: [config], paths: sample.paths).copied == 0)

            try FileManager.default.removeItem(at: config.appendingPathComponent("file-history"))
            let (deliver, _) = Self.files(sample)
            let version = try #require(try await FileProvenance.history(of: deliver, index: index, paths: sample.paths).versions.first)
            let copy = try #require(version.copy)
            #expect(copy.path.hasPrefix(KeptFileHistory.root(paths: sample.paths).path))
            #expect(try String(contentsOf: copy, encoding: .utf8) == FixtureHome.deliverBefore)
        }
    }
}
