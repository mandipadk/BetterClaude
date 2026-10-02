import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Secrets")
struct SecretsTests {
    @Test("Keys are found with who put them there, never kept whole, and hidden from what Claude reads")
    func sweep() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let keys = FixtureHome.sampleKeys
            let findings = SecretSweep.sweep(SecretSweep.files(in: snapshot))
            let anthropic = try #require(findings.first { $0.kind.id == "anthropic" })
            let aws = try #require(findings.first { $0.kind.id == "aws" })
            #expect(findings.count == 2)
            #expect(anthropic.sightings.first?.source == .pasted)
            #expect(aws.sightings.first?.source == .commandOutput, "\(aws.sightings)")
            #expect(!anthropic.masked.contains(String(keys.anthropic.dropFirst(14).dropLast(4))))
            #expect(anthropic.masked.hasSuffix(String(keys.anthropic.suffix(4))))
            #expect(anthropic.fingerprint == SecretSweep.fingerprint(keys.anthropic))

            try await index.update(from: snapshot)
            let recall = Recall(index: index, accounts: [RecallTests.personal])
            let found = try await recall.search(query: "staging check key", project: nil, sinceDays: nil, limit: 5)
            #expect(SecretSweep.redact(found).contains("[anthropic api key hidden]") || !found.contains(keys.anthropic))
            #expect(!SecretSweep.redact("key \(keys.anthropic) and \(keys.aws)").contains(keys.aws))
        }
    }

    @Test("Words that merely contain a prefix, and long encoded blobs, aren't keys")
    func falsePositives() {
        let blob = "sk-" + String(repeating: "A1b2C3d4", count: 60)
        #expect(SecretSweep.matches(in: "the task-\(String(repeating: "abcdefgh", count: 6)) finished").isEmpty)
        #expect(SecretSweep.matches(in: blob).isEmpty)
        #expect(SecretSweep.matches(in: "-----BEGIN PRIVATE KEY----- goes here in the docs").isEmpty)
        let real = "sk-" + "proj-" + String(repeating: "Zx9Q", count: 12)
        #expect(SecretSweep.matches(in: "OPENAI_API_KEY=\(real)").first?.kind.id == "openai")
    }

    static let anthropic = "sk-" + "ant-" + "api03-" + String(repeating: "Wd4kP9test", count: 9) + "AA"
    static let github = "gh" + "p_" + String(repeating: "T3stK3yAbc", count: 4)

    private func sweep(_ lines: [String]) throws -> [SecretSweep.Finding] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return SecretSweep.sweep([("c", file)])
    }

    private func record(_ content: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["role": "user", "content": content]]), as: UTF8.self)
    }

    @Test("A key right after an escaped line break or tab in the raw file is still a key")
    func keysAfterEscapes() throws {
        let found = try sweep([try record("first line\n\(Self.anthropic)"), try record("col\t\(Self.github)")])
        #expect(Set(found.map(\.kind.id)) == ["anthropic", "github"])
        #expect(found.first { $0.kind.id == "anthropic" }?.fingerprint == SecretSweep.fingerprint(Self.anthropic))
        #expect(SecretSweep.matches(in: #"quoted\u0022"# + Self.github).first?.value == Self.github)
        // Still not the tail of a longer word.
        #expect(SecretSweep.matches(in: "an" + Self.github).isEmpty)
    }

    @Test("A key running past the stretch read around an earlier prefix is taken whole")
    func keysPastTheWindow() throws {
        let line = try record("sk-x is not a key. " + String(repeating: "y", count: 290) + " " + Self.anthropic + " done")
        let found = try sweep([line])
        #expect(found.map(\.fingerprint) == [SecretSweep.fingerprint(Self.anthropic)])
    }

    @Test("Private keys are found escaped twice over, and hidden through their last line")
    func privateKeys() {
        let body = (0..<3).map { "MIIEv" + String(repeating: "QUFBQkNE", count: 7) + "\($0)" }
        let begin = "-----BEGIN " + "PRIVATE KEY-----"
        let end = "-----END " + "PRIVATE KEY-----"
        let doubled = begin + #"\\n"# + body.joined(separator: #"\\n"#) + #"\\n"# + end
        #expect(SecretSweep.matches(in: doubled).first?.kind.id == "private-key")
        let plain = "key:\n" + begin + "\n" + body.joined(separator: "\n") + "\n" + end + "\nafter"
        let hidden = SecretSweep.redact(plain)
        #expect(body.allSatisfy { !hidden.contains($0) })
        #expect(hidden.hasSuffix("[private key hidden]\nafter"))
        #expect(body.allSatisfy { !SecretSweep.redact(doubled).contains($0) })
    }

    @Test("Sub-agents' transcripts are swept too, as part of their conversation")
    func subagentTranscripts() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, _ in
            let conversation = try #require(snapshot.conversations.first { $0.transcriptURL != nil && $0.external == nil })
            let transcript = try #require(conversation.transcriptURL)
            let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((try record("use \(Self.github) for the clone") + "\n").utf8)
                .write(to: folder.appendingPathComponent("agent-a1b2.jsonl"))

            #expect(SecretSweep.files(in: snapshot).contains { $0.url.lastPathComponent == "agent-a1b2.jsonl" })
            let github = try #require(SecretSweep.sweep(SecretSweep.files(in: snapshot)).first { $0.kind.id == "github" })
            #expect(github.conversations == [conversation.id])
            #expect(github.sightings.first?.source == .pasted)
        }
    }

    @Test("A rotated key is remembered by its fingerprint only")
    func handled() throws {
        try FixtureHomeTests.withSample { sample in
            try HandledSecrets.save(["abc123"], paths: sample.paths)
            #expect(HandledSecrets.load(paths: sample.paths) == ["abc123"])
        }
    }
}
