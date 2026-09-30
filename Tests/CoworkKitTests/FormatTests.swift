import Foundation
import Testing

@testable import CoworkKit

/// The shapes of real Claude Code and Codex files, one per version, taken with
/// `cowork formats --write Tests/CoworkKitTests/Corpus` (`make corpus`). They hold field
/// names and types only.
@Suite("Formats")
struct FormatTests {

    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Corpus")

    static func shapes(_ contract: FormatContract) throws -> [FormatShape] {
        let folder = corpus.appendingPathComponent(contract.format)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let shapes = try files.map { try FormatShape.decode(Data(contentsOf: $0)) }
        let byVersion = Dictionary(uniqueKeysWithValues: shapes.map { ($0.version, $0) })
        return FormatSurvey.ordered(byVersion.keys).compactMap { byVersion[$0] }
    }

    @Test("Every version in the corpus has what Better Claude reads, and nothing unreviewed", arguments: ["claude-code", "codex"])
    func corpusHolds(_ format: String) throws {
        let contract = format == "codex" ? FormatContract.codex : .claudeCode
        let shapes = try Self.shapes(contract)
        #expect(shapes.count >= 10)
        for shape in shapes {
            #expect(shape.format == contract.format)
            let findings = contract.check(shape)
            #expect(findings.isEmpty, "\(contract.name) \(shape.version): \(findings.map(\.description).joined(separator: "; "))")
        }
    }

    @Test("The corpus holds names and types, never content")
    func corpusIsContentFree() throws {
        let segment = /^([A-Za-z_][A-Za-z0-9_]*|\*)(\[[A-Za-z0-9_.<>\-]*\])?$/
        let types: Set<String> = ["null", "bool", "int", "number", "string", "array", "object"]
        for contract in [FormatContract.claudeCode, .codex] {
            for shape in try Self.shapes(contract) {
                #expect(FormatShape.isNameValue(shape.version))
                for (kind, entry) in shape.kinds {
                    #expect(kind.split(separator: "/").allSatisfy { $0 == "*" || FormatShape.isNameValue(String($0)) })
                    for (path, seen) in entry.fields {
                        for part in path.split(separator: ".") {
                            #expect(part.wholeMatch(of: segment) != nil, "\(shape.version) \(kind): \(part)")
                            let name = part.split(separator: "[").first.map(String.init) ?? ""
                            #expect(name == "*" || FormatShape.isFieldName(name), "\(shape.version) \(kind): \(name)")
                        }
                        #expect(Set(seen).isSubset(of: types))
                    }
                    for (path, values) in entry.values {
                        #expect(contract.valuePaths.contains(path))
                        for value in values { #expect(FormatShape.isNameValue(value)) }
                    }
                }
            }
        }
    }

    @Test("A shape keeps field names and drops paths, ids, addresses and text")
    func shapesDropContent() throws {
        let records = [
            #"{"type":"assistant","version":"9.9.9","uuid":"4f1c2a","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/Volumes/Sample/secret-project","message":{"id":"msg_01SECRETID","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"the launch code is swordfish"},{"type":"tool_use","id":"toolu_01ABCdefGHIjkl","name":"Bash","input":{"command":"cat secret.txt","customerName":"Ada"}}]},"wireToolInputs":{"toolu_01ABCdefGHIjkl":{"x":1}},"lookup":{"ada@example.com":1,"toolu_01ABCdefGHIjkl":2,"a9f3c2e1b4d5f6a7b8c9":3}}"#,
            #"{"type":"file-history-snapshot","messageId":"m1","snapshot":{"messageId":"m1","trackedFileBackups":{"src/secret-plans.md":{"backupFileName":"abc@v1","version":1,"backupTime":"2026-09-01T10:00:00.000Z"}},"timestamp":"2026-09-01T10:00:00.000Z"}}"#,
            #"{"type":"system","subtype":"Very Secret Subtype With Spaces","content":"hidden"}"#,
        ]
        var shape = FormatShape(format: "claude-code", version: "9.9.9")
        for record in records { FormatContract.claudeCode.absorb(try JSONValue.parse(record), into: &shape) }
        let text = String(decoding: try shape.encoded(), as: UTF8.self)
        for secret in ["secret", "swordfish", "Ada", "customerName", "example.com", "toolu_", "msg_01", "a9f3c2", "cat ", "Spaces", "hidden", "4f1c2a", "abc@v1"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        let assistant = try #require(shape.kinds["assistant"])
        #expect(assistant.fields["message.content[tool_use].input.command"] == ["string"])
        #expect(assistant.fields["message.content[text].text"] == ["string"])
        #expect(assistant.fields["lookup.*"] == ["int"])
        #expect(assistant.values["message.model"] == ["claude-opus-5"])
        #expect(shape.kinds["file-history-snapshot"]?.fields["snapshot.trackedFileBackups.*.version"] == ["int"])
        #expect(shape.kinds["system/*"] != nil)
    }

    @Test("A renamed field, a changed type, a new kind and a new model are each caught")
    func driftIsCaught() throws {
        var shape = try #require(try Self.shapes(.claudeCode).last)
        #expect(FormatContract.claudeCode.check(shape).isEmpty)

        shape.kinds["assistant"]?.fields["message.usage.input_tokens"] = ["string"]
        shape.kinds["assistant"]?.values["message.model"]?.append("claude-nova-7")
        var delta = try #require(shape.kinds["file-history-delta"])
        delta.fields["path"] = ["string"]
        delta.fields["trackingPath"] = nil
        shape.kinds["file-history-delta"] = delta
        shape.kinds["file-history-patch"] = FormatShape.Kind()

        let findings = FormatContract.claudeCode.check(shape)
        #expect(findings.contains(.missing(kind: "file-history-delta", path: "trackingPath", feature: "file versions")))
        #expect(findings.contains(.changedType(kind: "assistant", path: "message.usage.input_tokens", seen: ["string"], feature: "token usage")))
        #expect(findings.contains(.unknownKind("file-history-patch")))
        #expect(findings.contains(.unpricedModel("claude-nova-7")))
        #expect(findings.filter(\.breaksSomething).count == 2)
    }

    @Test("A file version Claude Code wrote on its own, outside any snapshot, is read")
    func fileHistoryDelta() throws {
        let record = try JSONValue.parse(#"{"type":"file-history-delta","messageId":"a2","snapshotMessageId":"u1","trackingPath":"src/app.swift","backup":{"backupFileName":null,"version":1,"backupTime":"2026-09-01T10:00:00.000Z","realParentDir":"/Volumes/Sample/app/src"},"timestamp":"2026-09-01T10:00:00.000Z"}"#)
        var result = TranscriptScan()
        TranscriptScanner.absorb(record, into: &result)
        let version = try #require(result.fileVersions.first)
        #expect(version.path == "src/app.swift" && version.version == 1 && version.backupFileName == nil)
        #expect(version.messageID == "u1" && version.backupTime != nil)
    }

    @Test("The reader shows a conversation's pull requests and where it came from or went on")
    func pullRequestsAndRelatives() throws {
        let records = try [
            #"{"type":"pr-link","sessionId":"s1","prNumber":42,"prRepository":"acme/app","prUrl":"https://github.com/acme/app/pull/42","timestamp":"2026-09-01T10:00:00.000Z"}"#,
            #"{"type":"pr-link","sessionId":"s1","prNumber":42,"prRepository":"acme/app","prUrl":"https://github.com/acme/app/pull/42","timestamp":"2026-09-01T10:05:00.000Z"}"#,
            #"{"type":"pr-link","sessionId":"s1","prUrl":"javascript:alert(1)"}"#,
            #"{"type":"branched-from","sessionId":"s1","sourceSessionId":"s0","cutUuid":"u9","cutMessageIndex":3,"branchedAt":"2026-09-01T09:00:00.000Z"}"#,
            #"{"type":"continued-in","sessionId":"s1","continuedInSessionId":"s2","timestamp":"2026-09-01T11:00:00.000Z"}"#,
        ].map { try JSONValue.parse($0) }
        let readable = ReadableConversation(transcript: Transcript(records: records))
        #expect(readable.pullRequests.map(\.name) == ["acme/app#42"])
        #expect(readable.relatives == [.forkedFrom("s0"), .continuedIn("s2")])

        var scan = TranscriptScan()
        for record in records { TranscriptScanner.absorb(record, into: &scan) }
        #expect(scan.pullRequests.count == 2 && scan.pullRequests.allSatisfy { $0.number == 42 })
    }

    @Test("Versions sort by their numbers")
    func versionOrder() {
        #expect(FormatSurvey.ordered(["2.1.10", "2.1.9", "2.0.100", "0.146.0-alpha.9.2", "0.146.0-alpha.3.1"])
                == ["0.146.0-alpha.3.1", "0.146.0-alpha.9.2", "2.0.100", "2.1.9", "2.1.10"])
    }

    // MARK: Records built from each version's shape

    /// A record with every field the shape has, holding placeholder values.
    static func sample(_ kind: String, _ shape: FormatShape.Kind) -> JSONValue {
        final class Node {
            var children: [String: Node] = [:]
            var elements: [String: Node] = [:]
            var types: [String] = []
            var path = ""
        }
        let root = Node()
        for (path, types) in shape.fields {
            var node = root
            var walked: [String] = []
            for part in path.split(separator: ".").map(String.init) {
                let name = part.split(separator: "[", maxSplits: 1).first.map(String.init) ?? part
                walked.append(name)
                let child = node.children[name] ?? Node()
                node.children[name] = child
                node = child
                node.path = walked.joined(separator: ".")
                if let open = part.firstIndex(of: "[") {
                    let label = String(part[part.index(after: open)..<part.index(before: part.endIndex)])
                    let element = node.elements[label] ?? Node()
                    node.elements[label] = element
                    element.path = node.path
                    node = element
                }
            }
            node.types = types
        }
        let parts = kind.split(separator: "/", maxSplits: 1).map(String.init)
        let stamp = "2026-09-01T10:00:00.000Z"
        func value(_ node: Node, key: String) -> JSONValue {
            switch node.path {
            case "type": return .string(parts[0])
            case "subtype": return .string(parts.count > 1 ? parts[1] : "")
            case "attachment.type", "payload.type": return .string(parts.count > 1 ? parts[1] : "")
            case "payload.role": return .string("assistant")
            case "message.model": return .string("claude-opus-5")
            case "prUrl": return .string("https://example.com/pull/1")
            case "message.role": return .string(kind == "user" ? "user" : "assistant")
            default: break
            }
            if !node.children.isEmpty {
                return .object(JSONObject(node.children.sorted { $0.key < $1.key }.map { key, child in
                    (key == "*" ? "sample/file.txt" : key, value(child, key: key))
                }))
            }
            if !node.elements.isEmpty {
                return .array(node.elements.sorted { $0.key < $1.key }.map { label, element in
                    var item = value(element, key: key)
                    if !label.isEmpty { item["type"] = .string(label) }
                    return item
                })
            }
            if node.types.contains("string") {
                return .string(key.lowercased().contains("time") ? stamp : "sample")
            }
            if node.types.contains("int") { return .int(1) }
            if node.types.contains("number") { return .double(1.5) }
            if node.types.contains("bool") { return .bool(false) }
            if node.types.contains("object") { return .object(JSONObject()) }
            if node.types.contains("array") { return .array([]) }
            return .null
        }
        return value(root, key: "")
    }

    @Test("What each Claude Code version wrote reads back as messages, usage, tools, files and failures")
    func claudeCodeSamplesScan() throws {
        for shape in try Self.shapes(.claudeCode) {
            func scan(_ kind: String) -> TranscriptScan? {
                guard let entry = shape.kinds[kind] else { return nil }
                var result = TranscriptScan()
                TranscriptScanner.absorb(Self.sample(kind, entry), into: &result)
                return result
            }
            let label = "Claude Code \(shape.version)"
            if let entry = shape.kinds["assistant"], let result = scan("assistant") {
                if entry.fields["message.usage.input_tokens"] != nil { #expect(result.usage.count == 1, "\(label) usage") }
                if entry.fields["message.content[tool_use].name"] != nil { #expect(!result.toolCalls.isEmpty, "\(label) tools") }
                if entry.fields["message.content[text].text"] != nil { #expect(!result.messages.isEmpty, "\(label) replies") }
            }
            if let entry = shape.kinds["user"] {
                var record = Self.sample("user", entry)
                // A prompt is either a plain string or text blocks; tool results come back as
                // user records too, so write it the way this version has prompts.
                if entry.fields["message.content[text].text"] == nil, entry.fields["message.content"]?.contains("string") == true {
                    record["message"]?["content"] = .string("sample")
                }
                var result = TranscriptScan()
                TranscriptScanner.absorb(record, into: &result)
                #expect(!result.messages.isEmpty, "\(label) prompts")
            }
            if shape.kinds["file-history-snapshot"]?.fields["snapshot.trackedFileBackups.*.version"] != nil {
                #expect(scan("file-history-snapshot")?.fileVersions.isEmpty == false, "\(label) snapshots")
            }
            if let result = scan("file-history-delta") { #expect(!result.fileVersions.isEmpty, "\(label) file deltas") }
            if let result = scan("system/away_summary") { #expect(result.messages.first?.kind == .recap, "\(label) recaps") }
            if let result = scan("pr-link") { #expect(!result.pullRequests.isEmpty, "\(label) pull requests") }
            if let result = scan("cost-state") { #expect(result.cost != nil, "\(label) cost") }
            if let result = scan("ai-title") { #expect(result.title != nil, "\(label) titles") }
            if let result = scan("attachment/hook_non_blocking_error") { #expect(!result.health.isEmpty, "\(label) hooks") }
            if shape.kinds["attachment/deferred_tools_delta"]?.fields["attachment.failedMcpServers[].name"] != nil {
                #expect(scan("attachment/deferred_tools_delta")?.health.isEmpty == false, "\(label) MCP failures")
            }
        }
    }

    @Test("What each Codex version wrote reads back as its prompts, replies and tools")
    func codexSamplesScan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-shapes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for shape in try Self.shapes(.codex) {
            let kinds = ["session_meta", "turn_context", "response_item/message", "response_item/function_call"]
            let lines = try kinds.compactMap { kind -> String? in
                guard let entry = shape.kinds[kind] else { return nil }
                return String(decoding: try Self.sample(kind, entry).serialized(), as: UTF8.self)
            }
            let file = folder.appendingPathComponent("rollout-\(shape.version).jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            let result = try CodexSessions.scan(file)
            #expect(result.cwd == "sample", "Codex \(shape.version) project")
            if shape.kinds["response_item/message"]?.fields["payload.content[output_text].text"] != nil {
                #expect(result.messages.contains { $0.role == .assistant }, "Codex \(shape.version) replies")
            }
            if shape.kinds["response_item/function_call"] != nil {
                #expect(!result.toolCalls.isEmpty, "Codex \(shape.version) tools")
            }
        }
    }
}
