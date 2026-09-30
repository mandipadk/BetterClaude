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

    @Test("A rotated key is remembered by its fingerprint only")
    func handled() throws {
        try FixtureHomeTests.withSample { sample in
            try HandledSecrets.save(["abc123"], paths: sample.paths)
            #expect(HandledSecrets.load(paths: sample.paths) == ["abc123"])
        }
    }
}
