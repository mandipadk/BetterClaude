import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Memory health")
struct MemoryHealthTests {
    @Test("Lines past the cut, notes nothing links to, and links to notes that are gone; linking is undoable")
    func health() throws {
        try FixtureHomeTests.withSample { sample in
            let folder = sample.root.appendingPathComponent("memory", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var index = ["- [Stack](stack.md) — what the app is built on", "- [Old decision](gone.md) — removed since"]
            index += (1...208).map { "- entry \($0)" }
            try Data(index.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("MEMORY.md"))
            try Data("---\nname: stack\ndescription: what the app is built on\n---\nSwiftUI.".utf8).write(to: folder.appendingPathComponent("stack.md"))
            try Data("---\nname: release-flow\ndescription: how a release goes out\n---\nTag, then publish.".utf8)
                .write(to: folder.appendingPathComponent("release-flow.md"))

            let health = try #require(MemoryHealth.check(folder: folder))
            #expect(health.linesPastCut == 10)
            #expect(health.unlinked.map(\.lastPathComponent) == ["release-flow.md"])
            #expect(health.missing == ["gone.md"])

            let before = try Data(contentsOf: folder.appendingPathComponent("MEMORY.md"))
            let receipt = try health.link(health.unlinked, paths: sample.paths)
            #expect(receipt.direction == .memoryEdit)
            let after = try #require(MemoryHealth.check(folder: folder))
            #expect(after.unlinked.isEmpty)
            let text = try String(contentsOf: folder.appendingPathComponent("MEMORY.md"), encoding: .utf8)
            // Near the top, inside the cut.
            #expect(text.components(separatedBy: "\n")[2] == "- [Release flow](release-flow.md) — how a release goes out")

            _ = try Undo.revert(receipt)
            #expect(try Data(contentsOf: folder.appendingPathComponent("MEMORY.md")) == before)
        }
    }
}
