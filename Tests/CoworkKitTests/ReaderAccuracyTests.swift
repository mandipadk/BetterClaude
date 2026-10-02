import Foundation
import Testing

@testable import CoworkKit

/// Synthetic transcripts in the shapes Claude Code writes.
private enum Lines {
    static func records(_ lines: [String]) throws -> [JSONValue] {
        try lines.map { try JSONValue.parse(Data($0.utf8)) }
    }

    static func user(_ uuid: String, parent: String?, _ content: String, at second: Int = 0) -> String {
        let parentValue = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"user","uuid":"\#(uuid)","parentUuid":\#(parentValue),"timestamp":"2026-09-01T10:00:\#(String(format: "%02d", second)).000Z","message":{"role":"user","content":\#(content)}}"#
    }

    static func assistant(_ uuid: String, parent: String?, _ text: String, id: String? = nil, at second: Int = 0) -> String {
        let parentValue = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":\#(parentValue),"timestamp":"2026-09-01T10:00:\#(String(format: "%02d", second)).000Z","message":{"id":"\#(id ?? "msg-" + uuid)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    static func string(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
    }

    static func blocks(_ texts: [String]) -> String {
        "[" + texts.map { #"{"type":"text","text":\#(string($0))}"# }.joined(separator: ",") + "]"
    }
}

private extension ReadableConversation {
    var messages: [MessageText] {
        entries.compactMap { if case .message(let message) = $0 { return message }; return nil }
    }
    var notices: [Notice] {
        entries.compactMap { if case .notice(let notice) = $0 { return notice }; return nil }
    }
}

@Suite("What a person typed")
struct InjectedTurnTests {

    @Test("Text a tool wrote into the person's turn reads as a quiet line or not at all")
    func injectedTextIsNotTyped() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"npm test\" completed (exit code 0)</summary>\n</task-notification>")),
            Lines.user("u2", parent: "u1", Lines.string("<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args>12</command-args>")),
            Lines.user("u3", parent: "u2", Lines.string("<local-command-stdout>Reviewed</local-command-stdout>")),
            Lines.user("u4", parent: "u3", Lines.string("<bash-input>ls -la</bash-input><bash-stdout>total 0</bash-stdout><bash-stderr></bash-stderr>")),
            Lines.user("u5", parent: "u4", Lines.string("[Request interrupted by user]")),
            Lines.user("u6", parent: "u5", Lines.string("<system-reminder>Remember the plan.</system-reminder>")),
            Lines.user("u7", parent: "u6", Lines.string("<uploaded_files>\n<file><file_path>/tmp/a.csv</file_path></file>\n</uploaded_files>\nSum the second column")),
            Lines.assistant("a1", parent: "u7", "The total is 12."),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.text) == ["Sum the second column", "The total is 12."])
        #expect(readable.notices.map(\.kind) == [.notification, .command, .shell, .interrupted])
        #expect(readable.notices.map(\.text) == ["Background command \"npm test\" completed (exit code 0)",
                                                 "Ran /review 12", "! ls -la", "You interrupted Claude"])

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.messages.map(\.text) == ["Sum the second column", "The total is 12."])
    }

    @Test("A turn whose first block a tool wrote keeps the block the person typed")
    func typedSecondBlockSurvives() throws {
        let content = Lines.blocks(["<command-name>/model</command-name>\n<command-args>opus</command-args>",
                                    "Now rename the flag to --dry-run"])
        let records = try Lines.records([Lines.user("u1", parent: nil, content)])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.notices.map(\.text) == ["Ran /model opus"])
        #expect(readable.messages.map(\.text) == ["Now rename the flag to --dry-run"])

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.messages.map(\.text) == ["Now rename the flag to --dry-run"])
        #expect(scan.modelMarkers.map(\.kind) == [.requested])
    }

    @Test("Codex's own wrappers aren't taken for something typed")
    func codexWrappers() {
        for text in ["<recommended_plugins>\n- a\n</recommended_plugins>", "<skill>\nname: x\n</skill>",
                     "<codex_internal_context>{}</codex_internal_context>", "<image name=[Image #1]>", "</image>",
                     "<environment_context>\n<cwd>/tmp</cwd>\n</environment_context>",
                     "<user_instructions>Be brief</user_instructions>", "<turn_aborted>\nstopped\n</turn_aborted>"] {
            #expect(InjectedContext.contains(text), "\(text)")
        }
        let parts = InjectedContext.parts(ofBlocks: ["Look at this", "<image name=[Image #1]>", "</image>"])
        #expect(InjectedContext.typedText(parts) == "Look at this")
        #expect(InjectedContext.typedText(InjectedContext.parts(ofBlocks: ["<pasted_content>a long paste</pasted_content>"]))
                == "a long paste")
        #expect(InjectedContext.parts(ofBlocks: ["The following is the Codex agent history", "Fix it"]).isEmpty)
    }

    @Test("A prompt queued while Claude worked is the person's; a queued notification isn't")
    func queuedPrompts() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("Build it")),
            Lines.assistant("a1", parent: "u1", "Building."),
            #"{"type":"attachment","uuid":"q1","parentUuid":"a1","timestamp":"2026-09-01T10:00:05.000Z","attachment":{"type":"queued_command","prompt":"Also add tests","commandMode":"prompt","origin":{"kind":"human"}}}"#,
            #"{"type":"attachment","uuid":"q2","parentUuid":"q1","timestamp":"2026-09-01T10:00:06.000Z","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"And a README"}],"commandMode":"prompt","origin":{"kind":"human"}}}"#,
            #"{"type":"attachment","uuid":"q3","parentUuid":"q2","timestamp":"2026-09-01T10:00:07.000Z","attachment":{"type":"queued_command","prompt":"<task-notification><summary>done</summary></task-notification>","commandMode":"task-notification"}}"#,
            #"{"type":"attachment","uuid":"q4","parentUuid":"q3","timestamp":"2026-09-01T10:00:08.000Z","attachment":{"type":"queued_command","prompt":"From another session","commandMode":"prompt","origin":{"kind":"peer"}}}"#,
            Lines.assistant("a2", parent: "q4", "Done, with tests and a README.", at: 9),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.text) == ["Build it", "Building.", "Also add tests", "And a README",
                                                  "Done, with tests and a README."])
        #expect(readable.messages[2].role == .user)

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.messages.filter { $0.role == .user }.map(\.text) == ["Build it", "Also add tests", "And a README"])
    }

    @Test("An API error reads as a notice, not as Claude's reply, and isn't indexed as one")
    func apiErrors() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("Hello")),
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","isApiErrorMessage":true,"timestamp":"2026-09-01T10:00:01.000Z","message":{"id":"x","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: 529 Overloaded"}]}}"#,
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.role) == [.user])
        #expect(readable.notices.map(\.kind) == [.apiError])
        #expect(readable.notices.first?.text == "API Error: 529 Overloaded")

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.messages.map(\.role) == [.user])
    }

    @Test("An image the person sent shows as a placeholder, even with nothing typed")
    func imagePlaceholders() throws {
        let content = #"[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"document","title":"spec.pdf","source":{"type":"base64","data":"AAAA"}}]"#
        let readable = ReadableConversation(transcript: Transcript(records: try Lines.records([
            Lines.user("u1", parent: nil, content),
        ])))
        #expect(readable.messages.count == 1)
        #expect(readable.messages.first?.text == "")
        #expect(readable.messages.first?.attachments == ["Image", "spec.pdf"])
    }
}

@Suite("Which records the reader shows")
struct ActiveChainTests {

    @Test("A record written twice is read once, and entry ids stay unique")
    func duplicateRecords() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("First")),
            Lines.assistant("a1", parent: "u1", "Reply"),
            Lines.user("u1", parent: nil, Lines.string("First, written again")),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.text) == ["First", "Reply"])

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.messages.map(\.text) == ["First", "Reply"])

        let repeated = ReadableConversation.uniquingIDs([
            .notice(.init(id: "n", kind: .command, text: "Ran /a", timestamp: nil)),
            .notice(.init(id: "n", kind: .command, text: "Ran /b", timestamp: nil)),
        ])
        #expect(Set(repeated.map(\.id)).count == 2)
    }

    @Test("A rewound attempt is left out, with a line where it began")
    func rewoundBranch() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("Write a parser")),
            Lines.assistant("a1", parent: "u1", "Here's a parser."),
            Lines.user("u2", parent: "a1", Lines.string("Make it recursive")),
            Lines.assistant("a2", parent: "u2", "Now it's recursive."),
            Lines.user("u3", parent: "a1", Lines.string("Make it iterative")),
            Lines.assistant("a3", parent: "u3", "Now it's iterative."),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.text) == ["Write a parser", "Here's a parser.", "Make it iterative",
                                                  "Now it's iterative."])
        guard readable.entries.count == 5, case .notice(let notice) = readable.entries[2] else {
            Issue.record("expected the rewound line between the first reply and the retry")
            return
        }
        #expect(notice.kind == .rewound)
        #expect(notice.text == "An earlier attempt was rewound")
    }

    @Test("Parallel tool calls and a compaction stay on the conversation")
    func parallelToolsAndCompaction() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("Read both files")),
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]}}"#,
            #"{"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"two"}]}}"#,
            Lines.assistant("a3", parent: "r2", "Both are short."),
            #"{"type":"system","subtype":"compact_boundary","uuid":"c1","parentUuid":null,"logicalParentUuid":"a3","compactMetadata":{"trigger":"manual","preTokens":1000,"postTokens":100}}"#,
            #"{"type":"user","uuid":"s1","parentUuid":"c1","isCompactSummary":true,"message":{"role":"user","content":"We read two files."}}"#,
            Lines.user("u2", parent: "s1", Lines.string("Thanks")),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.notices.isEmpty)
        #expect(readable.messages.map(\.text) == ["Read both files", "Both are short.", "Thanks"])
        let tools = readable.entries.compactMap { if case .tools(_, let names) = $0 { return names }; return nil }
        #expect(tools == [["Read", "Read"]])
        #expect(readable.entries.contains { if case .compaction(let c) = $0 { return c.summary == "We read two files." }; return false })
    }

    @Test("Without one chain to follow, everything shows in file order")
    func fallsBackToFileOrder() throws {
        let records = try Lines.records([
            Lines.user("u1", parent: nil, Lines.string("One")),
            Lines.assistant("a1", parent: "u1", "Two"),
            Lines.user("u2", parent: "gone", Lines.string("Three")),
            Lines.assistant("a2", parent: "u2", "Four"),
        ])
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.messages.map(\.text) == ["One", "Two", "Three", "Four"])
        #expect(readable.notices.isEmpty)
    }

    @Test("A conversation scanned from outside keeps its compactions and recaps")
    func scannedKinds() {
        var scan = TranscriptScan()
        scan.messages = [
            .init(uuid: "1", role: .user, kind: .message, timestamp: nil, text: "Hi"),
            .init(uuid: "2", role: .user, kind: .compaction, timestamp: nil, text: "Summary"),
            .init(uuid: "3", role: .system, kind: .recap, timestamp: nil, text: "Recap"),
        ]
        let readable = ReadableConversation(scan: scan, model: nil)
        #expect(readable.messageCount == 1)
        guard readable.entries.count == 3, case .compaction(let compaction) = readable.entries[1],
              case .recap(_, let text, _) = readable.entries[2] else {
            Issue.record("expected message, compaction, recap")
            return
        }
        #expect(compaction.summary == "Summary" && text == "Recap")
    }

    @Test("A reply's usage is dated by its first record, and markers from the index still land before it")
    func replyTimes() throws {
        var scan = TranscriptScan()
        for line in [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"thinking","thinking":""}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-09-01T10:00:09.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":5},"content":[{"type":"text","text":"Hi"}]}}"#,
        ] {
            TranscriptScanner.absorb(try JSONValue.parse(Data(line.utf8)), into: &scan)
        }
        #expect(scan.usage.count == 1)
        #expect(scan.usage.first?.output == 5)
        #expect(scan.usage.first?.timestamp == Transcript.parseTimestamp("2026-09-01T10:00:00.000Z"))

        let time = try #require(Transcript.parseTimestamp("2026-09-01T10:00:00.123Z"))
        let marker = TimelineMarker(id: "m", at: time.addingTimeInterval(0.0000004), kind: .cacheBreak(gap: 3_600, cost: 0.1))
        #expect(TimelineMarkers.anchors([marker], times: [time.addingTimeInterval(-5), time])[1]?.map(\.id) == ["m"])
    }
}

@Suite("Conversation titles")
struct TitleRulesTests {

    private func title(_ lines: [String]) throws -> (String, TitleSource) {
        Transcript(records: try Lines.records(lines)).resolvedTitle()
    }

    @Test("The first prompt skips what tools wrote, and names commands and shell input")
    func firstPromptRules() throws {
        #expect(try title([
            Lines.user("u1", parent: nil, Lines.string("<local-command-caveat>Caveat</local-command-caveat>")),
            Lines.user("u2", parent: "u1", Lines.string("[Request interrupted by user]")),
            Lines.user("u3", parent: "u2", Lines.string("Fix the login redirect")),
        ]) == ("Fix the login redirect", .firstPrompt))
        #expect(try title([
            Lines.user("u1", parent: nil, Lines.string("<command-name>/clear</command-name>\n<command-args></command-args>")),
            Lines.user("u2", parent: "u1", Lines.string("<command-name>/deploy</command-name>\n<command-message>deploy</command-message>\n<command-args>staging</command-args>")),
        ]).0 == "/deploy staging")
        #expect(try title([
            Lines.user("u1", parent: nil, Lines.string("<command-name>/clear</command-name>\n<command-args></command-args>")),
        ]).0 == "/clear")
        #expect(try title([Lines.user("u1", parent: nil, Lines.string("<bash-input>git status</bash-input>"))]).0
                == "! git status")
        let long = String(repeating: "word ", count: 60)
        let clipped = try title([Lines.user("u1", parent: nil, Lines.string(long))]).0
        #expect(clipped.hasSuffix("…") && clipped.count <= 201)
    }

    @Test("Titles follow Claude Code's order: agent name, given title, Claude's title, summary, prompt")
    func titleOrder() throws {
        let prompt = Lines.user("u1", parent: nil, Lines.string("Plan the launch"))
        let summary = #"{"type":"summary","summary":"Launch planning","leafUuid":"u1"}"#
        let ai = #"{"type":"ai-title","aiTitle":"Launch plan","sessionId":"s"}"#
        let custom = #"{"type":"custom-title","customTitle":"Q4 launch","sessionId":"s"}"#
        let agent = #"{"type":"agent-name","agentName":"launch-bot","sessionId":"s"}"#
        #expect(try title([prompt]) == ("Plan the launch", .firstPrompt))
        #expect(try title([summary, prompt]) == ("Launch planning", .summary))
        #expect(try title([summary, prompt, ai]) == ("Launch plan", .aiTitle))
        #expect(try title([summary, prompt, ai, custom]) == ("Q4 launch", .customTitle))
        #expect(try title([summary, prompt, ai, custom, agent]) == ("launch-bot", .agentName))
    }

    @Test("A title kept beside the transcript counts when the transcript has none")
    func sidecarTitle() throws {
        try withProject { project in
            let url = project.appendingPathComponent("1f0e0000-0000-4000-8000-000000000001.jsonl")
            try write([Lines.user("u1", parent: nil, Lines.string("Plan the launch")),
                       #"{"type":"ai-title","aiTitle":"Launch plan","sessionId":"s"}"#], to: url)
            let folder = url.deletingPathExtension()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"customTitle":"Renamed"}"#.utf8).write(to: folder.appendingPathComponent("custom-title.json"))
            #expect(try Transcript(contentsOf: url).resolvedTitle() == ("Renamed", .customTitle))
            let sessions = try Discovery.claudeCodeSessions(projectDir: project, configDir: project)
            #expect(sessions.map(\.title) == ["Renamed"])
        }
    }

    @Test("A file of nothing but bookkeeping isn't listed as a conversation")
    func bookkeepingOnly() throws {
        try withProject { project in
            try write([#"{"type":"bridge-session","sessionId":"s","timestamp":"2026-09-01T10:00:00.000Z"}"#],
                      to: project.appendingPathComponent("1f0e0000-0000-4000-8000-000000000002.jsonl"))
            try write([Lines.user("u1", parent: nil, Lines.string("Hello"))],
                      to: project.appendingPathComponent("1f0e0000-0000-4000-8000-000000000003.jsonl"))
            #expect(try Discovery.claudeCodeSessions(projectDir: project, configDir: project).map(\.title) == ["Hello"])
        }
    }

    @Test("Last active is the last message, never later than the file")
    func lastActive() throws {
        try withProject { project in
            let url = project.appendingPathComponent("1f0e0000-0000-4000-8000-000000000004.jsonl")
            try write([
                Lines.user("u1", parent: nil, Lines.string("Hello"), at: 1),
                Lines.assistant("a1", parent: "u1", "Hi", at: 2),
                #"{"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","timestamp":"2026-09-01T10:00:50.000Z"}"#,
                #"{"type":"attachment","uuid":"t2","parentUuid":"t1","timestamp":"2026-09-01T10:00:55.000Z","attachment":{"type":"hook_success"}}"#,
                #"{"type":"last-prompt","lastPrompt":"Hello","sessionId":"s"}"#,
            ], to: url)
            let session = try #require(try Discovery.claudeCodeSessions(projectDir: project, configDir: project).first)
            #expect(session.lastTimestamp == Transcript.parseTimestamp("2026-09-01T10:00:02.000Z"))

            let early = try #require(Transcript.parseTimestamp("2026-09-01T10:00:01.500Z"))
            try FileManager.default.setAttributes([.modificationDate: early], ofItemAtPath: url.path)
            let clamped = try #require(try Discovery.claudeCodeSessions(projectDir: project, configDir: project).first)
            #expect(abs(clamped.lastTimestamp.timeIntervalSince(early)) < 1)
        }
    }

    @Test("The folder comes from the tail when the head of a long transcript names none")
    func cwdFromTail() throws {
        try withProject { project in
            let url = project.appendingPathComponent("1f0e0000-0000-4000-8000-000000000005.jsonl")
            let padding = String(repeating: "x", count: 2_000)
            var lines = [Lines.user("u1", parent: nil, Lines.string("Hello"))]
            for index in 0..<100 { lines.append(#"{"type":"progress","uuid":"p\#(index)","data":"\#(padding)"}"#) }
            lines.append(#"{"type":"user","uuid":"u2","parentUuid":"u1","cwd":"/work/app","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"user","content":"Bye"}}"#)
            lines.append(#"{"type":"last-prompt","lastPrompt":"Bye","sessionId":"s"}"#)
            try write(lines, to: url)
            let session = try #require(try Discovery.claudeCodeSessions(projectDir: project, configDir: project).first)
            #expect(session.resolvedCwd == "/work/app")
        }
    }

    private func withProject(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}

@Suite("Exports")
struct ReadableExportTests {
    @Test("Markdown comes from what the reader shows, under the right name")
    func markdownFromReadable() {
        var scan = TranscriptScan()
        scan.messages = [
            .init(uuid: "1", role: .user, kind: .message, timestamp: nil, text: "Rename it"),
            .init(uuid: "2", role: .assistant, kind: .message, timestamp: nil, text: "Renamed."),
        ]
        let markdown = MarkdownExport.render(ReadableConversation(scan: scan, model: nil), title: "Rename",
                                             assistantName: "Codex")
        #expect(markdown.contains("## You\n\nRename it"))
        #expect(markdown.contains("## Codex\n\nRenamed."))
        #expect(!markdown.contains("·"))
    }
}

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test("Nested lists keep their levels, and numbering carries on around them")
    func nestedLists() {
        let blocks = MarkdownBlock.parse("1. First\n   - inside\n     + deeper\n2. Second\n+ plus bullet")
        #expect(blocks == [.list([
            .init(level: 0, marker: .number(1), text: "First"),
            .init(level: 1, marker: .bullet, text: "inside"),
            .init(level: 2, marker: .bullet, text: "deeper"),
            .init(level: 0, marker: .number(2), text: "Second"),
            .init(level: 0, marker: .bullet, text: "plus bullet"),
        ])])
    }

    @Test("Table cells split only on pipes that aren't escaped or in code")
    func tableCells() {
        let blocks = MarkdownBlock.parse("| Flag | Meaning |\n|---|---|\n| `a|b` | either \\| or |\n| x | |")
        #expect(blocks == [.table(header: ["Flag", "Meaning"], rows: [["`a|b`", "either | or"], ["x", ""]])])
    }

    @Test("A code fence inside a list item drops the item's indentation")
    func fenceInList() {
        let blocks = MarkdownBlock.parse("- Run:\n   ```sh\n   make test\n     indented\n   ```")
        #expect(blocks == [.list([.init(level: 0, marker: .bullet, text: "Run:")]),
                           .code(language: "sh", text: "make test\n  indented")])
    }
}
