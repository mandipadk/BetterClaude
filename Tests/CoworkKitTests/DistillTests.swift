import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Distill")
struct DistillTests {

    static func history(_ prompts: [(String, String)], in config: URL) throws {
        let lines = try prompts.enumerated().map { index, prompt in
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "display": prompt.0, "project": prompt.1, "timestamp": 1_790_000_000_000 + index * 1000,
                "pastedContents": [String: String](), "sessionId": "s\(index)",
            ]), as: UTF8.self)
        }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: config.appendingPathComponent("history.jsonl"))
    }

    @Test("Repeated prompts are found, near-identical wordings count as one, and chatter doesn't")
    func promptLibrary() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        try Self.history([
            ("Run the tests and fix anything that fails", "/p/a"),
            ("run the tests and fix anything that fails.", "/p/b"),
            ("Run the tests, and fix anything that fails!", "/p/a"),
            ("Run all the tests and fix anything that fails", "/p/a"),
            ("yes", "/p/a"), ("yes", "/p/a"), ("yes", "/p/a"),
            ("/compact", "/p/a"), ("/compact", "/p/a"), ("/compact", "/p/a"),
            ("Write the release notes for this version", "/p/a"),
        ], in: config)
        let found = PromptLibrary.repeated(configDirs: [config], minimumUses: 3)
        #expect(found.count == 1)
        #expect(found.first?.uses == 4)
        #expect(found.first?.variants == 1)
        #expect(found.first?.projects.first == "/p/a")
        #expect(found.first?.text == "Run all the tests and fix anything that fails")
    }

    @Test("A prompt becomes a skill with a sensible name, and Undo takes it out")
    func skills() throws {
        try FixtureHomeTests.withSample { sample in
            var draft = SkillFactory.draft(from: "Please run the tests and fix anything that fails.")
            #expect(draft.name == "run-tests-fix-anything")
            #expect(draft.description.hasPrefix("Use when asked to run the tests"))
            #expect(draft.markdown.hasPrefix("---\nname: run-tests-fix-anything\n"))
            draft.name = "Not Valid"
            #expect(throws: SkillFactory.Failure.self) { try SkillFactory.install(draft, in: sample.paths.claudeCodeConfigDir) }

            draft.name = "run-tests"
            let receipt = try SkillFactory.install(draft, in: sample.paths.claudeCodeConfigDir)
            let file = sample.paths.claudeCodeConfigDir.appendingPathComponent("skills/run-tests/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(throws: SkillFactory.Failure.self) { try SkillFactory.install(draft, in: sample.paths.claudeCodeConfigDir) }
            _ = try Undo.revert(receipt)
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    @Test("Only narrow, harmless commands are suggested, and existing rules are respected")
    func commandPrefixes() {
        #expect(PermissionTuner.prefixes(of: "swift test --filter Quota 2>&1 | grep passed") == ["swift test", "grep"])
        #expect(PermissionTuner.prefixes(of: "cd /tmp && FOO=1 make build") == ["make build"])
        #expect(PermissionTuner.prefixes(of: "git push origin main").isEmpty)
        #expect(PermissionTuner.prefixes(of: "rm -rf build").isEmpty)
        #expect(PermissionTuner.prefixes(of: "python3 -c 'print(1)'").isEmpty)
        #expect(PermissionTuner.prefixes(of: "sed -i '' s/a/b/ file").isEmpty)
        #expect(PermissionTuner.prefixes(of: "for f in *; do echo $f; done") == ["echo"])
        #expect(PermissionTuner.prefixes(of: "/usr/bin/sudo ls").isEmpty)
        #expect(PermissionTuner.covered("swift test", by: ["Bash(swift:*)"]))
        #expect(PermissionTuner.covered("swift test", by: ["Bash(swift test:*)"]))
        #expect(!PermissionTuner.covered("swift test", by: ["Bash(swift build:*)"]))
        #expect(PermissionTuner.covered("grep", by: ["Bash"]))
    }

    @Test("Allowing rules backs up settings, keeps the person's own, and takes out only Better Claude's")
    func allowAndRemove() throws {
        try FixtureHomeTests.withSample { sample in
            let config = sample.paths.claudeCodeConfigDir
            try PermissionTuner.allow(["Bash(swift test:*)", "Bash(grep:*)"], configDir: config, paths: sample.paths)
            var rules = PermissionTuner.allowRules(configDir: config)
            #expect(rules.contains("Bash(swift test:*)") && rules.contains("Bash(grep:*)"))
            #expect(try JSONValue.parse(Data(contentsOf: config.appendingPathComponent("settings.json")))["model"]?.stringValue == "claude-opus-5-5")

            // A rule the person adds themselves stays when Better Claude's come out.
            try PermissionTuner.editAllow(configDir: config, paths: sample.paths) { $0.append("Bash(ls:*)") }
            try PermissionTuner.removeAdded(configDir: config, paths: sample.paths)
            rules = PermissionTuner.allowRules(configDir: config)
            #expect(rules == ["Bash(ls:*)"])
            #expect(PermissionTuner.added(configDir: config, paths: sample.paths).isEmpty)
        }
    }

    @Test("Failing MCP servers and hooks are read from the transcripts, without their output")
    func doctorAndDigest() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let url = try #require(conversation.transcriptURL)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: sample.now.addingTimeInterval(-60))
            let records: [[String: Any]] = [
                ["type": "attachment", "timestamp": stamp, "attachment": [
                    "type": "deferred_tools_delta", "addedNames": [String](),
                    "failedMcpServers": [["name": "notes", "errorCode": "ECONNREFUSED", "error": "connect failed"]],
                    "needsAuthMcpServers": ["calendar"]]],
                ["type": "attachment", "timestamp": stamp, "attachment": [
                    "type": "hook_non_blocking_error", "hookName": "Stop", "hookEvent": "Stop", "exitCode": 1,
                    "stderr": "secret-looking output", "command": "say done"]],
            ]
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            for record in records {
                try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8))
            }
            try handle.close()
            try await index.update(from: snapshot)

            let issues = try await Doctor.issues(index: index, installIDs: [conversation.installID],
                                                 since: sample.now.addingTimeInterval(-86_400))
            #expect(issues.contains { $0.kind == .mcpFailed && $0.name == "notes" && $0.detail == "ECONNREFUSED" })
            #expect(issues.contains { $0.kind == .mcpNeedsAuth && $0.name == "calendar" })
            #expect(issues.contains { $0.kind == .hookFailed && $0.detail == "Stop, exit 1" })
            let stored = try await index.rows("SELECT COUNT(*) FROM health WHERE detail LIKE '%secret%' OR name LIKE '%secret%'")
            #expect(stored.first?.int(0) == 0)

            let digest = try await WeekDigest.build(index: index, since: sample.now.addingTimeInterval(-7 * 86_400))
            #expect(digest.conversations > 0)
            #expect(digest.filesChanged >= 2)
            #expect(digest.projects.contains { $0.name == "billing-service" })
            #expect(digest.prompt.contains("Retry failed webhook deliveries with backoff"))
        }
    }
}

@Suite("Fleet")
struct FleetTests {
    @Test("An MCP server copies into another Desktop install beside its own, and Undo puts the file back")
    func copyServer() throws {
        try FixtureHomeTests.withSample { sample in
            let installs = InstallDiscovery.all()
            let claude = try #require(installs.first { $0.name == "Claude" })
            let work = try #require(installs.first { $0.name == "Claude Work" })
            let before = try Data(contentsOf: work.dataRoot.appendingPathComponent("claude_desktop_config.json"))

            let receipt = try Fleet.copyServer(named: "calendar", from: claude, to: work, paths: sample.paths)
            #expect(Fleet.serverEntry(named: "calendar", in: work, paths: sample.paths)?["command"]?.stringValue == "/usr/local/bin/calendar-mcp")
            #expect(Fleet.serverEntry(named: "linear", in: work, paths: sample.paths) != nil)
            #expect(throws: Fleet.Failure.self) { try Fleet.copyServer(named: "filesystem", from: claude, to: work, paths: sample.paths) }
            #expect(throws: Fleet.Failure.self) { try Fleet.copyServer(named: "nope", from: claude, to: work, paths: sample.paths) }
            // Better Claude's own server carries whose history it reads; it's never copied.
            #expect(throws: Fleet.Failure.self) { try Fleet.copyServer(named: "better-claude", from: claude, to: work, paths: sample.paths) }

            _ = try Undo.revert(receipt)
            #expect(try Data(contentsOf: work.dataRoot.appendingPathComponent("claude_desktop_config.json")) == before)
        }
    }
}
