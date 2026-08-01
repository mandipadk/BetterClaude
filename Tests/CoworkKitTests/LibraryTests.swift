import Foundation
import Testing

@testable import CoworkKit

/// The Library's value is entirely in what it *doesn't* show: a list that repeats the same
/// snippet twenty times, or that is 86% `node_modules`, is worse than no list. So the tests
/// here are mostly about exclusion — the threshold, the dedup, the walk — plus the title
/// inference that decides whether a row is recognisable at all.
@Suite("Library")
struct LibraryTests {

    // MARK: - Fixtures

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func write(_ contents: String, to url: URL) throws {
        try write(Data(contents.utf8), to: url)
    }

    private func message(_ role: String, _ text: String, uuid: String,
                         timestamp: String = "2026-03-11T20:56:15.545Z") -> JSONValue {
        .object(JSONObject([
            ("type", .string(role)),
            ("uuid", .string(uuid)),
            ("timestamp", .string(timestamp)),
            ("message", .object(JSONObject([
                ("role", .string(role)),
                ("content", .string(text)),
            ]))),
        ]))
    }

    private func harvestCode(_ text: String, conversation: String = "Chat",
                             id: String = "c1", at timestamp: String = "2026-03-11T20:56:15.545Z")
        -> [Artifact] {
        let transcript = Transcript(records: [
            message("assistant", text, uuid: "u1", timestamp: timestamp),
        ])
        return ArtifactHarvest.codeBlocks(in: transcript, conversationTitle: conversation,
                                          conversationID: id, container: "Claude")
    }

    // MARK: - Fence extraction

    @Test("A fence with a language tag yields one artifact carrying that language")
    func fenceWithLanguage() {
        let artifacts = harvestCode("""
        Here you go:

        ```swift
        func total(_ values: [Int]) -> Int {
            values.reduce(0, +)
        }
        ```

        That should do it.
        """)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].language == "swift")
        #expect(artifacts[0].kind == .code)
        #expect(artifacts[0].lineCount == 3)
        // The prose around the fence must not be swept into the block.
        #expect(artifacts[0].inlineContent?.contains("That should do it") == false)
        #expect(artifacts[0].inlineContent?.hasPrefix("func total") == true)
    }

    @Test("A fence with no language tag is still an artifact, with no language")
    func fenceWithoutLanguage() {
        let artifacts = harvestCode("""
        ```
        alpha_threshold = 1
        beta_threshold = 2
        gamma_threshold = 3
        ```
        """)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].language == nil)
        #expect(artifacts[0].lineCount == 3)
    }

    @Test("Language aliases are canonicalised")
    func canonicalisesLanguage() {
        let artifacts = harvestCode("""
        ```sh
        set -euo pipefail
        rsync -a "$SRC" "$DST"
        ```
        """)
        #expect(artifacts.first?.language == "shell")
    }

    @Test("Two fences in one message are two artifacts")
    func twoFences() {
        let artifacts = harvestCode("""
        First:

        ```python
        def load(path):
            return open(path).read()
        ```

        Then:

        ```python
        def save(path, body):
            open(path, "w").write(body)
        ```
        """)
        #expect(artifacts.count == 2)
    }

    @Test("An unterminated fence closes at the end of the message rather than being lost")
    func unterminatedFence() {
        let artifacts = harvestCode("""
        ```swift
        struct PartialResponse {
            let value: Int
            let receivedAt: Date
        """)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].inlineContent?.contains("struct PartialResponse") == true)
    }

    // MARK: - Noise threshold

    @Test("A one-line block is noise, not an artifact")
    func rejectsOneLiner() {
        // Long enough to clear the byte floor, so it is the line count doing the work.
        let artifacts = harvestCode("""
        ```bash
        ls -la /usr/local/share/really/quite/a/long/path/indeed/but/still/one/line
        ```
        """)
        #expect(artifacts.isEmpty)
    }

    @Test("A tiny multi-line block is noise too")
    func rejectsTinyBlock() {
        // Three lines but well under the byte floor.
        let artifacts = harvestCode("""
        ```
        a
        b
        c
        ```
        """)
        #expect(artifacts.isEmpty)
    }

    @Test("An empty fence yields nothing")
    func rejectsEmptyFence() {
        #expect(harvestCode("```swift\n\n```").isEmpty)
    }

    // MARK: - Title inference

    @Test("A function name becomes the title")
    func titleFromFunctionName() {
        let artifacts = harvestCode("""
        ```swift
        func rebuildSearchIndex(force: Bool) throws {
            try store.wipe()
        }
        ```
        """)
        #expect(artifacts.first?.title == "func rebuildSearchIndex")
    }

    @Test("A class or def name works the same way")
    func titleFromDeclaration() {
        #expect(harvestCode("""
        ```python
        class InvoiceParser:
            def __init__(self):
                pass
        ```
        """).first?.title == "class InvoiceParser")

        #expect(harvestCode("""
        ```python
        def normalise_rows(rows):
            return [r.strip() for r in rows]
        ```
        """).first?.title == "def normalise_rows")
    }

    @Test("A leading comment becomes the title")
    func titleFromLeadingComment() {
        let artifacts = harvestCode("""
        ```python
        # Rebuild the nightly rollup from the raw events table
        import datetime
        rows = fetch_events()
        ```
        """)
        #expect(artifacts.first?.title == "Rebuild the nightly rollup from the raw events table")
    }

    @Test("A comment that is only punctuation is not a title")
    func ignoresDecorativeComment() {
        let artifacts = harvestCode("""
        ```c
        /* ============================== */
        int main(void) { return 0; }
        ```
        """)
        // Falls through rather than titling the row with a rule of `=`. `int` is a type, not a
        // name, so the first informative word is what labels it.
        #expect(artifacts.first?.title == "c main")
    }

    @Test("With no comment and no declaration, the language and first identifier label it")
    func titleFromLanguageAndIdentifier() {
        let artifacts = harvestCode("""
        ```sql
        SELECT customer_id, total
        FROM invoices
        WHERE total > 100
        ```
        """)
        let title = try? #require(harvestCode("""
        ```sql
        SELECT customer_id, total
        FROM invoices
        WHERE total > 100
        ```
        """).first?.title)
        #expect(artifacts.first?.title.contains("sql") == true)
        // `select` is a keyword, not a name, so the first *informative* word wins.
        #expect(title?.contains("customer_id") == true)
    }

    @Test("Nothing is ever labelled only Untitled")
    func neverBareUntitled() {
        for source in ["```\n0000 1111 2222 3333\n4444 5555 6666 7777\n8888 9999 0000 1111\n```",
                       "```text\nlorem ipsum dolor sit\namet consectetur adipiscing\n```"] {
            let title = harvestCode(source).first?.title
            #expect(title?.isEmpty == false)
            #expect(title != "Untitled")
        }
    }

    // MARK: - Deduplication

    @Test("The same snippet in two conversations collapses to the earlier one")
    func collapsesAcrossConversations() {
        let block = """
        ```swift
        func retry(_ attempts: Int, _ body: () throws -> Void) rethrows {
            for _ in 0..<attempts { try body() }
        }
        ```
        """
        let later = harvestCode(block, conversation: "Second pass", id: "later",
                                at: "2026-05-02T10:00:00.000Z")
        let earlier = harvestCode(block, conversation: "First draft", id: "earlier",
                                  at: "2026-01-04T09:00:00.000Z")
        #expect(later[0].contentHash == earlier[0].contentHash)

        // Fed in newest-first, so keeping the earliest is a real choice rather than a side
        // effect of input order.
        let (kept, collapsed) = ArtifactHarvest.deduplicate(later + earlier)
        #expect(kept.count == 1)
        #expect(collapsed == 1)
        #expect(kept[0].conversationTitle == "First draft")
    }

    @Test("Different content is never collapsed")
    func keepsDistinctContent() {
        let a = harvestCode("```swift\nlet windowSize = 1\nlet retryBudget = 2\nlet name = 3\n```",
                            id: "a")
        let b = harvestCode("```swift\nlet windowSize = 3\nlet retryBudget = 4\nlet name = 5\n```",
                            id: "b")
        #expect(a.count == 1 && b.count == 1)
        let (kept, collapsed) = ArtifactHarvest.deduplicate(a + b)
        #expect(kept.count == 2)
        #expect(collapsed == 0)
    }

    @Test("An identical file and code block collapse together — the hash is the only key")
    func collapsesFileAgainstBlock() throws {
        try withScratch { root in
            let body = "def widen(rows):\n    return [r * 2 for r in rows]\n"
            try write(body, to: root.appendingPathComponent("outputs/widen.py"))
            let files = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Files",
                                              conversationID: "f", container: "Claude")
            let blocks = harvestCode("```python\n\(body)```", id: "b")
            #expect(files.count == 1)
            #expect(blocks.count == 1)
            #expect(files[0].contentHash == blocks[0].contentHash)
            #expect(ArtifactHarvest.deduplicate(files + blocks).kept.count == 1)
        }
    }

    // MARK: - The walk

    @Test("node_modules is excluded entirely")
    func excludesNodeModules() throws {
        try withScratch { root in
            try write("export const real = 1\nexport const thing = 2\n",
                      to: root.appendingPathComponent("outputs/app.js"))
            for index in 0..<5 {
                try write("module.exports = \(index)\n",
                          to: root.appendingPathComponent("outputs/node_modules/pkg\(index)/index.js"))
            }
            try write("deep\n", to: root.appendingPathComponent(
                "outputs/src/node_modules/nested/deep/thing.js"))

            let found = ArtifactHarvest.harvestFiles(inWorkspace: root, conversationTitle: "Chat",
                                                     conversationID: "c", container: "Claude")
            #expect(found.artifacts.map(\.title) == ["app.js"])
            #expect(found.skips["node_modules"] == 6)
        }
    }

    @Test("Dot files, dot directories and .DS_Store never appear")
    func excludesHiddenEntries() throws {
        try withScratch { root in
            try write("keep me\n", to: root.appendingPathComponent("outputs/report.md"))
            try write("junk", to: root.appendingPathComponent("outputs/.DS_Store"))
            try write("secret", to: root.appendingPathComponent("outputs/.env"))
            try write("cached", to: root.appendingPathComponent("outputs/.cache/blob.txt"))
            try write("gitish", to: root.appendingPathComponent("outputs/.git/config"))

            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            #expect(artifacts.map(\.title) == ["report.md"])
        }
    }

    @Test("Only uploads/ and outputs/ are walked")
    func walksOnlyTheTwoDirectories() throws {
        try withScratch { root in
            try write("in\n", to: root.appendingPathComponent("uploads/spec.txt"))
            try write("out\n", to: root.appendingPathComponent("outputs/result.txt"))
            try write("machine state\n", to: root.appendingPathComponent("audit.jsonl"))
            try write("more state\n", to: root.appendingPathComponent(".claude/settings.json"))

            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            #expect(Set(artifacts.map(\.title)) == ["spec.txt", "result.txt"])
            // A file the user supplied is an upload wherever it lands in the type system.
            #expect(artifacts.first { $0.title == "spec.txt" }?.kind == .upload)
        }
    }

    @Test("A missing workspace is empty, not an error")
    func toleratesMissingWorkspace() throws {
        try withScratch { root in
            let absent = root.appendingPathComponent("no-such-session", isDirectory: true)
            #expect(ArtifactHarvest.files(inWorkspace: absent, conversationTitle: "Chat",
                                          conversationID: "c", container: "Claude").isEmpty)
        }
    }

    // MARK: - Binary detection

    @Test("A NUL byte in the first 8 KiB marks a file binary and it is skipped")
    func detectsBinaryByNulSniff() throws {
        try withScratch { root in
            var blob = Data("MZ\u{0}\u{0}payload".utf8)
            blob.append(Data(repeating: 0x41, count: 4096))
            try write(blob, to: root.appendingPathComponent("outputs/tool.bin"))
            try write("plain text file\n", to: root.appendingPathComponent("outputs/notes.txt"))

            let found = ArtifactHarvest.harvestFiles(inWorkspace: root, conversationTitle: "Chat",
                                                     conversationID: "c", container: "Claude")
            #expect(found.artifacts.map(\.title) == ["notes.txt"])
            #expect(found.skips["binary"] == 1)
        }
    }

    @Test("A NUL past the sniff window does not make a text file binary")
    func sniffsOnlyTheHead() throws {
        try withScratch { root in
            var blob = Data(String(repeating: "text line here\n", count: 1000).utf8)
            #expect(blob.count > ArtifactHarvest.binarySniffBytes)
            blob.append(0x00)
            try write(blob, to: root.appendingPathComponent("outputs/long.txt"))

            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            #expect(artifacts.count == 1)
            #expect(artifacts[0].kind == .document)
        }
    }

    @Test("Images are kept as images and never read for line counts")
    func classifiesImages() throws {
        try withScratch { root in
            var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
            png.append(Data(repeating: 0x7F, count: 256))
            try write(png, to: root.appendingPathComponent("outputs/chart.png"))

            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            #expect(artifacts.count == 1)
            #expect(artifacts[0].kind == .image)
            #expect(artifacts[0].lineCount == nil)
        }
    }

    @Test("Data formats are classified apart from prose")
    func classifiesData() throws {
        try withScratch { root in
            try write("a,b\n1,2\n", to: root.appendingPathComponent("outputs/rows.csv"))
            try write("# Notes\n\nsome prose\n", to: root.appendingPathComponent("outputs/notes.md"))

            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            let byName = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.title, $0) })
            #expect(byName["rows.csv"]?.kind == .data)
            #expect(byName["notes.md"]?.kind == .document)
            #expect(byName["notes.md"]?.language == "markdown")
            #expect(byName["rows.csv"]?.lineCount == 2)
        }
    }

    // MARK: - Search

    @Test("Search matches a title")
    func searchMatchesTitle() throws {
        try withScratch { root in
            try write("x,y\n1,2\n", to: root.appendingPathComponent("outputs/quarterly-revenue.csv"))
            try write("nothing\nrelevant\n", to: root.appendingPathComponent("outputs/scratch.txt"))
            let artifacts = ArtifactHarvest.files(inWorkspace: root, conversationTitle: "Chat",
                                                  conversationID: "c", container: "Claude")
            let hits = ArtifactHarvest.search(artifacts, query: "revenue")
            #expect(hits.map(\.title) == ["quarterly-revenue.csv"])
        }
    }

    @Test("Search matches the body of an inline block")
    func searchMatchesContent() {
        let artifacts = harvestCode("""
        ```swift
        func migrate() {
            connection.execute("ALTER TABLE invoices ADD COLUMN settled_at")
        }
        ```
        """)
        #expect(ArtifactHarvest.search(artifacts, query: "settled_at").count == 1)
        #expect(ArtifactHarvest.search(artifacts, query: "ALTER invoices").count == 1)
        #expect(ArtifactHarvest.search(artifacts, query: "kubernetes").isEmpty)
    }

    @Test("Search also reaches the conversation an artifact came from")
    func searchMatchesProvenance() {
        let artifacts = harvestCode("""
        ```swift
        let connectionLimit = 24
        let statementTimeout = 30
        ```
        """, conversation: "Postgres migration")
        #expect(artifacts.count == 1)
        #expect(ArtifactHarvest.search(artifacts, query: "postgres").count == 1)
    }

    @Test("An empty query filters nothing")
    func emptyQueryKeepsEverything() {
        let artifacts = harvestCode("```swift\nlet alpha = 1\nlet beta = 2\nlet gamma = 3\n```")
        #expect(artifacts.count == 1)
        #expect(ArtifactHarvest.search(artifacts, query: "").count == artifacts.count)
        #expect(ArtifactHarvest.search(artifacts, query: "   ").count == artifacts.count)
    }

    // MARK: - Whole harvest

    @Test("A harvest reports what it kept, collapsed and skipped")
    func harvestSummarises() throws {
        try withScratch { root in
            let workspace = root.appendingPathComponent("local_1", isDirectory: true)
            try write("id,total\n1,10\n2,20\n", to: workspace.appendingPathComponent("outputs/rows.csv"))
            try write("module.exports = 1\n",
                      to: workspace.appendingPathComponent("outputs/node_modules/a/index.js"))

            let block = "```swift\nfunc sharedAnswer() -> Int {\n    41 + 1\n}\n```"
            let transcript = root.appendingPathComponent("t.jsonl")
            let records = [message("assistant", block, uuid: "u1")]
            try Transcript(records: records).write(to: transcript)

            let summary = ArtifactHarvest.harvest(sources: [
                HarvestSource(conversationTitle: "One", conversationID: "one", container: "Claude",
                              transcriptURL: transcript, workspaceURL: workspace),
                HarvestSource(conversationTitle: "Two", conversationID: "two", container: "Claude",
                              transcriptURL: transcript, workspaceURL: nil),
            ])

            #expect(summary.conversationsScanned == 2)
            // The block appears in both conversations and collapses to one.
            #expect(summary.duplicatesCollapsed == 1)
            #expect(summary.count(of: .code) == 1)
            #expect(summary.count(of: .data) == 1)
            #expect(summary.totalBytes > 0)
            #expect(summary.skipped.contains { $0.hasPrefix("node_modules") })
        }
    }

    @Test("The concurrent harvest returns exactly what the serial one does")
    func concurrentMatchesSerial() async throws {
        try await withScratchAsync { root in
            var sources: [HarvestSource] = []
            for index in 0..<12 {
                let workspace = root.appendingPathComponent("local_\(index)", isDirectory: true)
                try write("row,value\n\(index),\(index * 2)\n",
                          to: workspace.appendingPathComponent("outputs/rows-\(index).csv"))
                // Every third conversation repeats the same snippet, so dedup has something
                // to do and the two paths have to agree about which origin survives.
                let body = index % 3 == 0
                    ? "func sharedHelper(_ input: [Int]) -> Int {\n    input.reduce(0, +)\n}"
                    : "func helper\(index)(_ input: [Int]) -> Int {\n    input.reduce(\(index), +)\n}"
                let transcript = root.appendingPathComponent("t\(index).jsonl")
                try Transcript(records: [
                    message("assistant", "```swift\n\(body)\n```", uuid: "u\(index)",
                            timestamp: "2026-03-\(String(format: "%02d", index + 1))T10:00:00.000Z"),
                ]).write(to: transcript)
                sources.append(HarvestSource(
                    conversationTitle: "Chat \(index)", conversationID: "c\(index)",
                    container: "Claude", transcriptURL: transcript, workspaceURL: workspace))
            }

            let serial = ArtifactHarvest.harvest(sources: sources)
            let concurrent = await ArtifactHarvest.harvest(sources: sources, maximumConcurrency: 4)

            #expect(serial.artifacts.map(\.id) == concurrent.artifacts.map(\.id))
            #expect(serial.duplicatesCollapsed == concurrent.duplicatesCollapsed)
            #expect(serial.totalBytes == concurrent.totalBytes)
            #expect(serial.duplicatesCollapsed == 3)
            #expect(concurrent.conversationsScanned == 12)
        }
    }

    @Test("The fence pre-filter finds exactly what parsing the whole transcript finds")
    func preFilterMatchesFullParse() throws {
        try withScratch { root in
            var records: [JSONValue] = []
            for index in 0..<40 {
                // Bulk that cannot hold a fence: this is what the pre-filter exists to skip.
                records.append(message("user", String(repeating: "no fences here. ", count: 200),
                                       uuid: "n\(index)"))
                if index % 5 == 0 {
                    records.append(message("assistant", """
                    Here:

                    ```python
                    def stage_\(index)(rows):
                        return [r for r in rows if r]
                    ```
                    """, uuid: "f\(index)"))
                }
            }
            let url = root.appendingPathComponent("t.jsonl")
            try Transcript(records: records).write(to: url)

            let whole = try Transcript(contentsOf: url)
            let fromWhole = ArtifactHarvest.codeBlocks(in: whole, conversationTitle: "Chat",
                                                       conversationID: "c", container: "Claude")
            let filtered = try #require(ArtifactHarvest.fencedRecords(at: url))
            let fromFiltered = ArtifactHarvest.codeBlocks(in: filtered, conversationTitle: "Chat",
                                                          conversationID: "c", container: "Claude")

            #expect(fromWhole.count == 8)
            #expect(fromWhole.map(\.contentHash) == fromFiltered.map(\.contentHash))
            #expect(fromWhole.map(\.title) == fromFiltered.map(\.title))
            #expect(fromWhole.map(\.createdAt) == fromFiltered.map(\.createdAt))
            // And it really did skip the bulk rather than parsing everything anyway.
            #expect(filtered.records.count == 8)
        }
    }

    /// `withScratch` takes a non-escaping throwing body; an async test needs the same lifetime
    /// without the closure crossing an `await`, so the directory is torn down here instead.
    private func withScratchAsync(_ body: (URL) async throws -> Void) async rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}
