import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Claims")
struct ClaimsTests {
    @Test("Claims are read from what was said, and plans aren't claims")
    func reading() {
        #expect(Claims.claims(in: "Done. All tests pass.").map(\.1) == [.testsPass])
        #expect(Claims.claims(in: "I updated deliver.ts to retry.").first?.2 == "deliver.ts")
        #expect(Claims.claims(in: "Once the tests pass I'll update deliver.ts.").isEmpty)
        #expect(Claims.claims(in: "Upgraded to version 2.1.0 today.").isEmpty)
        #expect(Claims.claims(in: "Committed and pushed to main.").map(\.1) == [.committed, .pushed])
    }

    @Test("Library names, version numbers and abbreviations aren't files; paths are kept as written")
    func fileNames() {
        #expect(Claims.claims(in: "I updated the server to Node.js 22.").isEmpty)
        #expect(Claims.claims(in: "Changed the loop, which made it 2.5x faster.").isEmpty)
        #expect(Claims.claims(in: "Updated the docs, e.g. the README.md intro.").first?.2 == "README.md")
        #expect(Claims.claims(in: "I edited Sources/App/Main.swift to fix it.").first?.2 == "Sources/App/Main.swift")
        #expect(Claims.claims(in: "Updated Node.js usage in ./src/server.ts as well.").first?.2 == "src/server.ts")
    }

    @Test("Only a real test runner or build counts, not a command that only mentions one")
    func runners() {
        for line in ["swift test", "cd pkg && swift test 2>&1 | tail -5", "FOO=1 pnpm test backoff", "npm run test",
                     "yarn test", "python3 -m pytest -q", "cargo test", "go test ./...", "xcodebuild -scheme App test", "make test"] {
            #expect(Claims.runs(Claims.testRun, line), "\(line) runs tests")
        }
        for line in ["ls tests/", "grep -rn test Sources", "cat .build/debug/test.log", "echo swift test", "swift build",
                     "git log --grep test", "find . -name '*test*'"] {
            #expect(!Claims.runs(Claims.testRun, line), "\(line) doesn't run tests")
        }
        for line in ["swift build -c release", "npm run build", "cargo build", "go build ./...", "xcodebuild -scheme App build", "make"] {
            #expect(Claims.runs(Claims.buildRun, line), "\(line) builds")
        }
        for line in ["ls .build", "rm -rf .build/debug", "grep build Package.swift", "make test", "open build/index.html"] {
            #expect(!Claims.runs(Claims.buildRun, line), "\(line) doesn't build")
        }
    }

    @Test("An edit claim matches the file by its path, not any file with the same name")
    func editedByPath() {
        let calls = [Claims.Call(name: "Edit", file: "/repo/Sources/A/Bar.swift", detail: nil, failed: false, at: nil)]
        #expect(Claims.strictJudge(.edited, file: "Sources/A/Bar.swift", calls: calls) == .backed("1 edit to Sources/A/Bar.swift"))
        #expect(Claims.strictJudge(.edited, file: "Bar.swift", calls: calls) == .backed("1 edit to Bar.swift"))
        #expect(Claims.strictJudge(.edited, file: "/repo/Sources/A/Bar.swift", calls: calls) == .backed("1 edit to /repo/Sources/A/Bar.swift"))
        #expect(Claims.strictJudge(.edited, file: "Sources/B/Bar.swift", calls: calls) == .noEvidence)
        #expect(Claims.strictJudge(.edited, file: "ar.swift", calls: calls) == .noEvidence)
    }

    @Test("A sub-agent's report is checked against what it did: backed, contradicted, or with no evidence")
    func verdicts() async throws {
        try await HistoryIndexTests.withSample { _, snapshot, index in
            try await index.update(from: snapshot)
            let conversation = try #require(snapshot.conversations.first { $0.title == "Retry failed webhook deliveries with backoff" })
            let claims = try await Claims.check(conversationID: conversation.id, index: index)
            let unbacked = try #require(claims.first { $0.agentID == "a1f0search" && $0.kind == .edited })
            #expect(unbacked.verdict == .noEvidence)
            let tests = try #require(claims.first { $0.agentID == "b2e1tests" && $0.kind == .testsPass })
            #expect(tests.verdict == .contradicted("the last run, pnpm test backoff, failed"))
            let wrote = try #require(claims.first { $0.agentID == "b2e1tests" && $0.kind == .edited })
            #expect(wrote.verdict == .backed("1 edit to backoff.test.ts"))
        }
    }
}
