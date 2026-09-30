import Foundation

/// What one pass over a transcript found, from a byte offset to the last complete line.
///
/// Transcripts only ever grow while Claude is writing them, so a live conversation is read
/// once and then only its new tail each time it changes — a 100 MB session that gained one
/// reply costs one reply's worth of parsing.
public struct TranscriptScan: Sendable {

    public struct Message: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// Something a person or Claude said.
            case message
            /// Claude's own short recap, written when the person stepped away.
            case recap
            /// The summary Claude wrote when it compacted the conversation.
            case compaction
        }
        public let uuid: String?
        public let role: MessageText.Role
        public let kind: Kind
        public let timestamp: Date?
        public let text: String
    }

    /// Tokens for one model reply. A reply is split across several records that repeat the
    /// same usage, so these are keyed by the API's message id and counted once.
    public struct Usage: Sendable, Equatable {
        public let messageID: String
        public let model: String
        public let timestamp: Date?
        public let input: Int64
        public let output: Int64
        public let cacheRead: Int64
        public let cacheWrite5m: Int64
        public let cacheWrite1h: Int64
    }

    public struct ToolCall: Sendable, Equatable {
        public let messageUUID: String?
        public let timestamp: Date?
        public let name: String
        /// The file the tool read or wrote, for the tools that name one.
        public let filePath: String?
        /// The command, for a shell call: its first line, trimmed.
        public var detail: String? = nil
        public var toolUseID: String? = nil
        /// Its result came back as an error: a command that exited non-zero, an edit that
        /// didn't apply.
        public var failed = false
    }

    /// Something that went wrong around a turn: an MCP server that failed to start or needs
    /// signing in to, or a hook that failed.
    public struct HealthEvent: Sendable, Equatable {
        public enum Kind: String, Sendable { case mcpFailed, mcpNeedsAuth, hookFailed }
        public let kind: Kind
        public let name: String
        /// The error code for a server, or the hook's event and exit status.
        public let detail: String?
        public let timestamp: Date?
    }

    /// One version of a file Claude Code saved before changing it, from a
    /// `file-history-snapshot` record.
    public struct FileVersion: Sendable, Equatable {
        public let path: String
        public let version: Int
        /// The copy's name in `file-history/<session>/`; `nil` when the file didn't exist yet,
        /// so this version is the moment Claude created it.
        public let backupFileName: String?
        public let backupTime: Date?
        /// The message the change belongs to.
        public let messageID: String?
    }

    /// Claude Code's own running total for the session.
    public struct CostState: Sendable, Equatable {
        public let totalUSD: Double
        public let linesAdded: Int64
        public let linesRemoved: Int64
    }

    /// A pull request Claude Code linked to the conversation.
    public struct PullRequest: Sendable, Equatable {
        public let url: String
        public let number: Int?
        public let repository: String?
        public let timestamp: Date?
    }

    /// Something that explains a change of model: you asked with /model, or Claude Code fell
    /// back after a refusal.
    public struct ModelMarker: Sendable, Equatable {
        public enum Kind: String, Sendable { case requested, fallback }
        public let kind: Kind
        public let timestamp: Date?
    }

    public var messages: [Message] = []
    public var pullRequests: [PullRequest] = []
    public var modelMarkers: [ModelMarker] = []
    public var usage: [Usage] = []
    public var toolCalls: [ToolCall] = []
    public var fileVersions: [FileVersion] = []
    public var health: [HealthEvent] = []
    public var cost: CostState?
    public var title: String?
    public var gitBranch: String?
    public var entrypoint: String?
    public var cwd: String?
    /// The folder the session started in: file-history paths are relative to it.
    public var firstCwd: String?
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?
    /// Where the next pass should start: just past the last complete line read.
    public var endOffset: Int64 = 0
    public var malformedLines = 0
}

public enum TranscriptScanner {

    /// Tools whose input names the file they act on.
    static let fileTools: [String: String] = [
        "Edit": "file_path", "Write": "file_path", "Read": "file_path", "MultiEdit": "file_path",
        "NotebookEdit": "notebook_path", "NotebookRead": "notebook_path",
    ]

    /// Reads `url` from `offset`. Stops at the last newline, so a line Claude is halfway
    /// through writing is picked up whole on the next pass.
    public static func scan(_ url: URL, from offset: Int64 = 0) throws -> TranscriptScan {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TranscriptError.unreadable(url: url, underlying: String(describing: error))
        }
        return scan(data, from: offset)
    }

    public static func scan(_ data: Data, from offset: Int64 = 0) -> TranscriptScan {
        var result = TranscriptScan()
        let start = Int(max(0, min(offset, Int64(data.count))))
        result.endOffset = Int64(start)

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var lineStart = start
            var cursor = start
            while cursor < bytes.count {
                if bytes[cursor] == 0x0A {
                    if cursor > lineStart {
                        let line = Data(bytes: buffer.baseAddress! + lineStart, count: cursor - lineStart)
                        if let record = try? JSONValue.parse(line) {
                            absorb(record, into: &result)
                        } else {
                            result.malformedLines += 1
                        }
                    }
                    lineStart = cursor + 1
                    result.endOffset = Int64(lineStart)
                }
                cursor += 1
            }
        }
        return result
    }

    /// Whether a later pass can start at `offset` rather than from the top: the file still
    /// has a line break just before it, so nothing before it was rewritten mid-line.
    public static func canResume(_ url: URL, at offset: Int64) -> Bool {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset - 1))) != nil,
              let byte = try? handle.read(upToCount: 1) else { return false }
        return byte.first == 0x0A
    }

    static func absorb(_ record: JSONValue, into result: inout TranscriptScan) {
        guard let type = record["type"]?.stringValue else { return }
        let timestamp = record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp)
        if let timestamp {
            if result.firstTimestamp == nil || timestamp < result.firstTimestamp! { result.firstTimestamp = timestamp }
            if result.lastTimestamp == nil || timestamp > result.lastTimestamp! { result.lastTimestamp = timestamp }
        }
        if let branch = record["gitBranch"]?.stringValue, !branch.isEmpty { result.gitBranch = branch }
        if let entrypoint = record["entrypoint"]?.stringValue { result.entrypoint = entrypoint }
        if let cwd = record["cwd"]?.stringValue, !cwd.isEmpty {
            result.cwd = cwd
            if result.firstCwd == nil { result.firstCwd = cwd }
        }

        switch type {
        case "user", "assistant":
            guard let message = record["message"] else { return }
            if type == "user" {
                for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result"
                    && block["is_error"]?.boolValue == true {
                    if let id = block["tool_use_id"]?.stringValue,
                       let at = result.toolCalls.lastIndex(where: { $0.toolUseID == id }) {
                        result.toolCalls[at].failed = true
                    }
                }
            }
            let uuid = record["uuid"]?.stringValue
            if type == "assistant" {
                absorbReply(message, uuid: uuid, timestamp: timestamp, into: &result)
            }
            if record["isMeta"]?.boolValue == true { return }
            let text = ConversationText.plainText(of: message)
            guard !text.isEmpty else { return }
            if type == "user", InjectedContext.contains(text) {
                if text.contains("<command-name>/model") {
                    result.modelMarkers.append(.init(kind: .requested, timestamp: timestamp))
                }
                return
            }
            let isCompaction = record["isCompactSummary"]?.boolValue == true
            result.messages.append(.init(uuid: uuid, role: type == "user" ? .user : .assistant,
                                         kind: isCompaction ? .compaction : .message,
                                         timestamp: timestamp, text: text))
        case "system":
            if record["subtype"]?.stringValue == "model_refusal_fallback" {
                result.modelMarkers.append(.init(kind: .fallback, timestamp: timestamp))
                return
            }
            guard record["subtype"]?.stringValue == "away_summary",
                  let text = record["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            result.messages.append(.init(uuid: record["uuid"]?.stringValue, role: .system, kind: .recap,
                                         timestamp: timestamp, text: text))
        case "custom-title":
            if let title = record["customTitle"]?.stringValue, !title.isEmpty { result.title = title }
        case "ai-title":
            if let title = record["aiTitle"]?.stringValue, !title.isEmpty { result.title = title }
        case "attachment":
            guard let attachment = record["attachment"] else { return }
            switch attachment["type"]?.stringValue {
            case "model":
                result.modelMarkers.append(.init(kind: .requested, timestamp: timestamp))
            case "deferred_tools_delta":
                for server in attachment["failedMcpServers"]?.arrayValue ?? [] {
                    guard let name = server["name"]?.stringValue else { continue }
                    result.health.append(.init(kind: .mcpFailed, name: name, detail: server["errorCode"]?.stringValue,
                                               timestamp: timestamp))
                }
                for name in attachment["needsAuthMcpServers"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                    result.health.append(.init(kind: .mcpNeedsAuth, name: name, detail: nil, timestamp: timestamp))
                }
            case "hook_non_blocking_error":
                // Only which hook and how it ended: its output can hold anything.
                let event = attachment["hookEvent"]?.stringValue ?? "hook"
                let status = attachment["exitCode"]?.intValue.map { "exit \($0)" } ?? "failed"
                result.health.append(.init(kind: .hookFailed, name: attachment["hookName"]?.stringValue ?? event,
                                           detail: "\(event), \(status)", timestamp: timestamp))
            default:
                break
            }
        case "file-history-snapshot":
            let snapshot = record["snapshot"]
            let messageID = record["messageId"]?.stringValue ?? snapshot?["messageId"]?.stringValue
            for (path, entry) in snapshot?["trackedFileBackups"]?.objectValue?.orderedPairs ?? [] {
                guard let version = entry["version"]?.intValue else { continue }
                result.fileVersions.append(.init(
                    path: path, version: Int(version), backupFileName: entry["backupFileName"]?.stringValue,
                    backupTime: entry["backupTime"]?.stringValue.flatMap(Transcript.parseTimestamp),
                    messageID: messageID))
            }
        case "file-history-delta":
            // Newer Claude Code writes each new version on its own instead of repeating every
            // tracked file in a snapshot; these versions appear in no snapshot.
            guard let path = record["trackingPath"]?.stringValue, let backup = record["backup"],
                  let version = backup["version"]?.intValue else { return }
            result.fileVersions.append(.init(
                path: path, version: Int(version), backupFileName: backup["backupFileName"]?.stringValue,
                backupTime: backup["backupTime"]?.stringValue.flatMap(Transcript.parseTimestamp),
                messageID: record["snapshotMessageId"]?.stringValue ?? record["messageId"]?.stringValue))
        case "pr-link":
            guard let url = record["prUrl"]?.stringValue, url.hasPrefix("https://") else { return }
            result.pullRequests.append(.init(url: url, number: record["prNumber"]?.intValue.map(Int.init),
                                             repository: record["prRepository"]?.stringValue, timestamp: timestamp))
        case "cost-state":
            result.cost = .init(totalUSD: record["totalCostUSD"]?.doubleValue ?? 0,
                                linesAdded: record["totalLinesAdded"]?.intValue ?? 0,
                                linesRemoved: record["totalLinesRemoved"]?.intValue ?? 0)
        default:
            return
        }
    }

    static func absorbReply(_ message: JSONValue, uuid: String?, timestamp: Date?,
                            into result: inout TranscriptScan) {
        if let id = message["id"]?.stringValue, let usage = message["usage"],
           let model = message["model"]?.stringValue, model != "<synthetic>" {
            let creation = usage["cache_creation"]
            let write1h = creation?["ephemeral_1h_input_tokens"]?.intValue ?? 0
            // Older transcripts only report the total cache write, which was always 5-minute.
            let write5m = creation?["ephemeral_5m_input_tokens"]?.intValue
                ?? (usage["cache_creation_input_tokens"]?.intValue ?? 0) - write1h
            let entry = TranscriptScan.Usage(
                messageID: id, model: model, timestamp: timestamp,
                input: usage["input_tokens"]?.intValue ?? 0,
                output: usage["output_tokens"]?.intValue ?? 0,
                cacheRead: usage["cache_read_input_tokens"]?.intValue ?? 0,
                cacheWrite5m: max(0, write5m), cacheWrite1h: write1h)
            if let last = result.usage.last, last.messageID == id {
                result.usage[result.usage.count - 1] = entry
            } else {
                result.usage.append(entry)
            }
        }
        for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
            guard let name = block["name"]?.stringValue else { continue }
            let path = fileTools[name].flatMap { block["input"]?[$0]?.stringValue }
            var call = TranscriptScan.ToolCall(messageUUID: uuid, timestamp: timestamp, name: name, filePath: path)
            call.toolUseID = block["id"]?.stringValue
            if name == "Bash", let command = block["input"]?["command"]?.stringValue {
                let first = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
                call.detail = String(first.trimmingCharacters(in: .whitespaces).prefix(300))
            }
            result.toolCalls.append(call)
        }
    }
}
