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

@Suite("Replay")
struct ReplayTests {
    static func message(_ ordinal: Int, _ role: MessageText.Role, _ text: String,
                        kind: TranscriptScan.Message.Kind = .message) -> IndexedMessage {
        IndexedMessage(ordinal: ordinal, uuid: nil, role: role, kind: kind, timestamp: nil, text: text)
    }

    @Test("Turns carry the real conversation before each prompt, merged and starting with the person")
    func turns() {
        let turns = Replay.turns(from: [
            Self.message(0, .assistant, "Hello, how can I help?"),
            Self.message(1, .user, "Add retries"),
            Self.message(2, .user, "with backoff"),
            Self.message(3, .assistant, "Done: five retries."),
            Self.message(4, .system, "recap", kind: .recap),
            Self.message(5, .user, "Cap it at ten minutes?"),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].prompt == "Add retries\n\nwith backoff")
        #expect(turns[0].original == "Done: five retries.")
        #expect(turns[0].history.isEmpty)
        #expect(turns[1].history.map(\.role) == ["user", "assistant"])
        #expect(turns[1].original == nil)
        #expect(Replay.messages(for: turns[1]).last?.text == "Cap it at ten minutes?")
        let estimate = Replay.estimate(turns, model: "claude-opus-5")
        #expect(estimate.inputTokens > 0 && estimate.dollars > 0)
        #expect(Replay.estimate(turns, model: "claude-fable-5-1").dollars > Replay.estimate(turns, model: "claude-haiku-4-5").dollars)
    }

    @Test("Requests are plain Messages API calls, and replies keep only their text")
    func wireFormat() throws {
        let request = AnthropicClient.request(model: "claude-opus-5", messages: [("user", "Hi")], maxTokens: 100)
        #expect(request["model"]?.stringValue == "claude-opus-5")
        #expect(request["messages"]?[0]?["content"]?.stringValue == "Hi")
        let body = try JSONValue.parse(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello"}],"stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":3}}"#)
        #expect(AnthropicClient.reply(from: body) == .init(text: "Hello", inputTokens: 9, outputTokens: 3, stopReason: "end_turn"))
        let refused = try JSONValue.parse(#"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":9,"output_tokens":0}}"#)
        #expect(AnthropicClient.reply(from: refused).text.contains("declined"))
    }
}
