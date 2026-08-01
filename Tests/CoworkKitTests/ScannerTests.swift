import Foundation
import Testing

@testable import CoworkKit

/// The scanner is the last thing standing between a user and a bundle that carries their
/// credentials, so its two failure modes are tested directly: missing a real secret, and
/// crying wolf so often that the warning stops meaning anything.
@Suite("Scanner")
struct ScannerTests {

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test("A planted Anthropic key blocks the export")
    func blocksAnthropicKey() throws {
        try withScratch { root in
            try write("the key is sk-ant-api03-\(String(repeating: "A", count: 24)) ok",
                      to: root.appendingPathComponent("outputs/notes.txt"))
            let report = try Scanner.scan(root: root)
            #expect(report.status == .block)
            #expect(report.findings.contains { $0.tier == "block" })
        }
    }

    @Test("Findings never contain the matched value")
    func neverLeaksTheValue() throws {
        try withScratch { root in
            let secret = "sk-ant-api03-\(String(repeating: "Z", count: 30))"
            try write("token: \(secret)", to: root.appendingPathComponent("a.txt"))
            let report = try Scanner.scan(root: root)
            #expect(report.status == .block)
            // A scanner that logs context has made a second copy of the secret.
            let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            #expect(!encoded.contains(secret))
            #expect(!encoded.contains(String(secret.dropFirst(14))))
        }
    }

    @Test("Hidden directories are traversed — that is where credentials live")
    func traversesHiddenDirectories() throws {
        try withScratch { root in
            // Default-ignore behaviour in ripgrep-family tools skips every `.claude/`
            // directory, which is precisely where `.credentials.json` sits. A scanner with
            // that default reports clean while shipping the tokens.
            try write(#"{"accessToken":"aaaaaaaaaaaaaaaaaaaaaaaa","serverName":"x"}"#,
                      to: root.appendingPathComponent(".claude/.credentials.json"))
            let report = try Scanner.scan(root: root)
            #expect(report.status == .block)
            #expect(report.findings.contains { $0.path.contains(".credentials.json") })
        }
    }

    @Test("Prose and placeholders do not block — the calibration target")
    func doesNotCryWolf() throws {
        try withScratch { root in
            // Every one of these appears in the real corpus and must not block: they are the
            // 200-odd raw regex hits that a naive scanner would report.
            try write("""
            password=hunter2placeholder
            export ANTHROPIC_API_KEY
            GITHUB_TOKEN is read from the environment
            api_key = your-api-key-here
            password: changeme
            secret_key = ${SECRET_KEY}
            auth_token = process.env.TOKEN
            The password was incorrect and the user retried.
            contact alice@example.com or bob@example.org
            """, to: root.appendingPathComponent("doc.md"))
            let report = try Scanner.scan(root: root)
            #expect(report.status != .block, "blocking findings: \(report.findings.map(\.ruleId))")
        }
    }

    @Test("An unreadable file blocks rather than being skipped")
    func unreadableBlocks() throws {
        try withScratch { root in
            let file = root.appendingPathComponent("locked.txt")
            try write("harmless", to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                           ofItemAtPath: file.path) }
            let report = try Scanner.scan(root: root)
            // Running as root would defeat the premise; only assert when the file really is
            // unreadable.
            if (try? Data(contentsOf: file)) == nil {
                #expect(report.status == .block)
                #expect(!report.unreadable.isEmpty)
            }
        }
    }

    @Test("Large files are scanned, not skipped by size")
    func scansLargeFiles() throws {
        try withScratch { root in
            // The biggest transcripts run to 20 MB and are exactly where a pasted key hides.
            let padding = String(repeating: "lorem ipsum dolor sit amet ", count: 60_000)
            try write(padding + "\nAKIAIOSFODNN7EXAMPLE\n" + padding,
                      to: root.appendingPathComponent("big.jsonl"))
            let report = try Scanner.scan(root: root)
            #expect(report.status == .block)
        }
    }
}
