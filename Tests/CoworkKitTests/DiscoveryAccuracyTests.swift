import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// Finding every conversation where it really is, and listing each once.
@Suite("Discovery accuracy")
struct DiscoveryAccuracyTests {

    private func makeOrg() throws -> URL {
        let org = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        return org
    }

    @Test("A Cowork workspace is found by its full session id or by the shorter name newer versions use")
    func workspaceNaming() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }
        let older = "local_11111111-2222-4333-8444-555555555555"
        try FileManager.default.createDirectory(at: org.appendingPathComponent(older), withIntermediateDirectories: true)
        #expect(Discovery.workspaceDirectory(org: org, sessionId: older, cwd: "/sessions/x").lastPathComponent == older)

        let newer = "local_208abb72-1111-4222-8333-444444444444"
        try FileManager.default.createDirectory(at: org.appendingPathComponent("208abb72/outputs"), withIntermediateDirectories: true)
        #expect(Discovery.workspaceDirectory(org: org, sessionId: newer, cwd: "/sessions/y").lastPathComponent == "208abb72")

        let hostLoop = "local_99999999-1111-4222-8333-444444444444"
        try FileManager.default.createDirectory(at: org.appendingPathComponent("elsewhere/outputs"), withIntermediateDirectories: true)
        let cwd = org.appendingPathComponent("elsewhere/outputs").path
        #expect(Discovery.workspaceDirectory(org: org, sessionId: hostLoop, cwd: cwd).lastPathComponent == "elsewhere")

        // Nothing there yet: the name the importer writes.
        let absent = "local_abcdefab-1111-4222-8333-444444444444"
        #expect(Discovery.workspaceDirectory(org: org, sessionId: absent, cwd: "").lastPathComponent == absent)
    }
}

extension DiscoveryAccuracyTests {
    @Test("A Parallex copy with a Claude Code of its own says where that is")
    func separateClaudeCode() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("claude-code").path
        let record: [String: Any] = [
            "slug": "lab", "name": "Claude Lab", "mode": "data-dir",
            "targetBundleID": Discovery.electronBundleIdentifier,
            "arguments": ["--user-data-dir=\(folder.appendingPathComponent("data").path)"],
            "environment": ["CLAUDE_CONFIG_DIR": config],
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("instance.json"))
        let instance = try #require(ParallexInstances.instance(at: folder))
        #expect(instance.claudeCodeConfigDir?.path == config)

        var plain = record
        plain["environment"] = [String: String]()
        try JSONSerialization.data(withJSONObject: plain).write(to: folder.appendingPathComponent("instance.json"))
        #expect(ParallexInstances.instance(at: folder)?.claudeCodeConfigDir == nil)
    }
}

extension DiscoveryAccuracyTests {
    @Test("A project's page holds exactly the conversations its row counts")
    func projectCountsAgree() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let projects = try await Projects.list(index: index)
            #expect(!projects.isEmpty)
            for project in projects {
                let detail = try await Projects.detail(of: project, index: index)
                #expect(detail.conversations.count == project.conversations, "\(project.path)")
            }
        }
    }
}

extension DiscoveryAccuracyTests {
    @Test("The accuracy check accounts for everything on the sample Mac and finds nothing out of place")
    func accuracyCheck() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let report = await AccuracyCheck.run(snapshot: snapshot, index: index)
            #expect(report.total + report.sources.reduce(0) { $0 + $1.archived } == snapshot.conversations.count)
            #expect(!report.issues.contains { $0.kind == .duplicateRow || $0.kind == .indexBehind || $0.kind == .indexAhead })
            let codex = try #require(report.sources.first { $0.name == "Codex" })
            #expect(codex.listed == 1)
            #expect(Set(codex.leftOut) == ["1 thread Codex started for a conversation",
                                           "1 automatic review of a command", "1 run by nightly-bot"])
        }
    }
}

extension DiscoveryAccuracyTests {
    @Test("How long Claude Code keeps conversations follows its own settings precedence")
    func cleanupPeriod() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let managed = dir.appendingPathComponent("managed.json")
        #expect(Vault.cleanupPeriod(configDir: dir, managed: managed) == 30 * 86_400)
        try Data(#"{"cleanupPeriodDays": 90}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        #expect(Vault.cleanupPeriod(configDir: dir, managed: managed) == 90 * 86_400)
        try Data(#"{"cleanupPeriodDays": 14}"#.utf8).write(to: dir.appendingPathComponent("settings.local.json"))
        #expect(Vault.cleanupPeriod(configDir: dir, managed: managed) == 14 * 86_400)
        try Data(#"{"cleanupPeriodDays": 7}"#.utf8).write(to: managed)
        #expect(Vault.cleanupPeriod(configDir: dir, managed: managed) == 7 * 86_400)
    }
}
