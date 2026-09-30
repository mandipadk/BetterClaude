import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Corrections")
struct CorrectionsTests {
    @Test("Corrections are told from ordinary prompts, and read as rules")
    func detect() {
        #expect(Corrections.isCorrection("No, use pnpm here, not npm."))
        #expect(Corrections.isCorrection("don't touch the migrations folder"))
        #expect(Corrections.isCorrection("use tabs instead of spaces"))
        #expect(!Corrections.isCorrection("Now add a test for the retry cap"))
        #expect(!Corrections.isCorrection("Notice anything odd in the logs?"))
        #expect(!Corrections.isCorrection("no"))
        #expect(Corrections.rule(from: "no, this repo uses pnpm not npm") == "This repo uses pnpm not npm.")
        #expect(Corrections.rule(from: "Please don't log request bodies") == "Don't log request bodies.")
    }

    @Test("The same correction in two conversations becomes one suggestion, and adding it is undoable")
    func suggestAndAdd() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let suggestions = try await Corrections.suggestions(index: index, paths: sample.paths)
            let billing = suggestions.filter { $0.project?.hasSuffix("billing-service") == true }
            #expect(billing.count == 2)
            let pnpm = try #require(billing.first { $0.rule.contains("pnpm") })
            #expect(pnpm.conversations == 2)

            let file = Corrections.target(for: pnpm.project, paths: sample.paths)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let receipt = try Corrections.add([pnpm.rule], to: file, paths: sample.paths)
            let written = try String(contentsOf: file, encoding: .utf8)
            #expect(written.contains("## Corrections from past sessions\n\n- \(pnpm.rule)"))
            let second = try Corrections.add(["Keep the retry cap at ten minutes."], to: file, paths: sample.paths)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("- \(pnpm.rule)\n- Keep the retry cap at ten minutes."))

            // Once it's in CLAUDE.md it isn't suggested again.
            let again = try await Corrections.suggestions(index: index, paths: sample.paths)
            #expect(!again.contains { $0.rule == pnpm.rule })

            _ = try Undo.revert(second)
            _ = try Undo.revert(receipt)
            let after = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!after.contains("pnpm"))
        }
    }
}

@Suite("Injected context")
struct InjectedContextTests {
    @Test("What tools write into the person's turn isn't taken for something typed")
    func injected() {
        var scan = TranscriptScan()
        for text in ["<task-notification>\n<task-id>1</task-id>", "<command-name>/compact</command-name>",
                     "Fix the flaky upload test"] {
            TranscriptScanner.absorb(.object(JSONObject([("type", .string("user")),
                                                         ("message", .object(JSONObject([("role", .string("user")), ("content", .string(text))])))])),
                                     into: &scan)
        }
        #expect(scan.messages.map(\.text) == ["Fix the flaky upload test"])
        #expect(InjectedContext.contains("Session goal: Build a tiny CLI"))
        #expect(InjectedContext.contains("  <subagent_notification>\n{}"))
        #expect(!InjectedContext.contains("Session goals are hard to write"))
    }
}
