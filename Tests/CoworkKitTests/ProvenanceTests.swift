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
            #expect(try await FileProvenance.recentFiles(index: index, matching: "backoff").map(\.path).contains(backoff))

            let history = try await FileProvenance.history(of: deliver, index: index, paths: sample.paths)
            #expect(history.versions.count == 2)
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

    @Test("A conversation's changes are the files as they were before it, and putting them back is one undoable step")
    func rewindConversation() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let (deliver, backoff) = Self.files(sample)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })

            let changes = try await ConversationRewind.changes(conversationID: conversation.id, index: index, paths: sample.paths)
            let edited = try #require(changes.files.first { $0.path == deliver })
            let created = try #require(changes.files.first { $0.path == backoff })
            #expect(edited.canPutBack && !edited.created && edited.existsNow)
            #expect(created.canPutBack && created.created)
            #expect(changes.puttable.count == 2)
            let recall = Recall(index: index, accounts: [RecallTests.personal])
            let described = try await recall.changes(id: conversation.cliSessionId ?? conversation.id)
            #expect(described.contains("backoff.ts") && described.contains("created by it"))

            let receipt = try ConversationRewind.putBack(changes.puttable, title: changes.title, paths: sample.paths)
            #expect(try String(contentsOfFile: deliver, encoding: .utf8) == FixtureHome.deliverBefore)
            #expect(!FileManager.default.fileExists(atPath: backoff))
            #expect(receipt.title == "Before “Retry failed webhook deliveries with backoff”")

            _ = try Undo.revert(receipt)
            #expect(try String(contentsOfFile: deliver, encoding: .utf8) == FixtureHome.deliverNow)
            #expect(try String(contentsOfFile: backoff, encoding: .utf8) == FixtureHome.backoffNow)
        }
    }

    @Test("An edit counts from when its result came back, not when Claude asked for it")
    func editResultTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rewind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Edit"}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:07:30.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:09:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_other","content":"ok"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        let times = ConversationRewind.resultTimes(in: transcript, editIDs: ["toolu_1": "/repo/a.swift"])
        #expect(times == ["/repo/a.swift": try #require(Transcript.parseTimestamp("2026-09-01T10:07:30.000Z"))])
    }

    @Test("File versions Claude Code keys relative to where the session started are found by their full path")
    func relativeVersions() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let url = try #require(conversation.transcriptURL)
            let record = #"{"type":"file-history-delta","messageId":"a9","snapshotMessageId":"u9","trackingPath":"src/webhooks/queue.ts","backup":{"backupFileName":null,"version":1,"backupTime":"2026-09-01T10:00:00.000Z"},"timestamp":"2026-09-01T10:00:00.000Z"}"#
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((record + "\n").utf8))
            try handle.close()
            try await index.update(from: snapshot)
            let root = sample.paths.home.appendingPathComponent("Code/billing-service").path
            let history = try await FileProvenance.history(of: root + "/src/webhooks/queue.ts", index: index, paths: sample.paths)
            #expect(history.createdByClaude)
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
            // Two saved versions of deliver.ts, and the plan.
            #expect(report.copied == 3)
            #expect(KeptFileHistory.keep(configDirs: [config], paths: sample.paths).copied == 0)

            try FileManager.default.removeItem(at: config.appendingPathComponent("file-history"))
            let (deliver, _) = Self.files(sample)
            let version = try #require(try await FileProvenance.history(of: deliver, index: index, paths: sample.paths).versions.first)
            let copy = try #require(version.copy)
            #expect(copy.path.hasPrefix(KeptFileHistory.root(paths: sample.paths).path))
            #expect(try String(contentsOf: copy, encoding: .utf8) == FixtureHome.deliverBefore)
        }
    }

    static func run(_ arguments: [String], in directory: URL, date: Date? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ["GIT_AUTHOR_NAME": "Alex", "GIT_AUTHOR_EMAIL": "alex@example.com",
                           "GIT_COMMITTER_NAME": "Alex", "GIT_COMMITTER_EMAIL": "alex@example.com",
                           "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1"]
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_AUTHOR_DATE"] = stamp
            environment["GIT_COMMITTER_DATE"] = stamp
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("A commit is linked to the conversation that changed its files just before it")
    func linksCommits() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let (deliver, _) = Self.files(sample)
            let repo = sample.paths.home.appendingPathComponent("Code/billing-service", isDirectory: true)
            try Self.run(["init", "-q"], in: repo)
            try Data("# billing\n".utf8).write(to: repo.appendingPathComponent("README.md"))
            try Self.run(["add", "README.md"], in: repo)
            try Self.run(["commit", "-q", "-m", "Start"], in: repo, date: sample.now.addingTimeInterval(-40 * 86_400))
            try Self.run(["add", "src"], in: repo)
            try Self.run(["commit", "-q", "-m", "Retry webhook deliveries"], in: repo, date: sample.now.addingTimeInterval(-2 * 3_600))

            let links = try await CommitLinker.commits(inRepository: repo, index: index)
            #expect(links.map(\.subject) == ["Retry webhook deliveries", "Start"])
            let match = try #require(links.first?.match)
            #expect(match.title == "Retry failed webhook deliveries with backoff")
            #expect(match.confidence == .likely)
            #expect(match.filesChanged == 2)
            #expect(links.last?.match == nil)

            let forFile = try await CommitLinker.commits(touching: deliver, index: index)
            #expect(forFile.map(\.subject) == ["Retry webhook deliveries"])
        }
    }

    @Test("A diff keeps the changed lines and a little context, and marks what it skips")
    func diffs() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...20).map { "line \($0)" }
        lines[4] = "line five, changed"
        lines.insert("brand new", at: 15)
        let diff = LineDiff(old: old, new: lines.joined(separator: "\n"), context: 1)
        #expect(diff.added == 2)
        #expect(diff.removed == 1)
        #expect(diff.lines.contains { $0.kind == .removed && $0.text == "line 5" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "line five, changed" })
        #expect(diff.lines.contains { $0.kind == .gap })
        #expect(!diff.lines.contains { $0.text == "line 10" })
        #expect(LineDiff(old: "same", new: "same").isEmpty)
        let created = LineDiff(old: "", new: "a\nb\n")
        #expect(created.added == 2 && created.removed == 0 && created.lines.count == 2)
    }
}
