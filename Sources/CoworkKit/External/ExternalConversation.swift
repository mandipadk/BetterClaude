import Foundation

/// A conversation from outside Claude's own apps: claude.ai, from its data export, or Codex.
/// Read only; Better Claude never writes to where these came from.
public struct ExternalConversation: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// Conversations from claude.ai, imported from its data export.
        case claudeWeb
        case codex

        public var name: String {
            switch self {
            case .claudeWeb: return "claude.ai"
            case .codex: return "Codex"
            }
        }
    }

    public let source: Source
    public let id: String
    /// The file holding this conversation, and only it.
    public let fileURL: URL
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date
    /// The folder it worked in, for Codex.
    public let cwd: String?
    public let model: String?

    public init(source: Source, id: String, fileURL: URL, title: String, createdAt: Date?, updatedAt: Date,
                cwd: String?, model: String?) {
        self.source = source
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.model = model
    }

    /// The conversation's messages, in order, as the index and the reader want them.
    public func scan() throws -> TranscriptScan {
        switch source {
        case .codex: return try CodexSessions.scan(fileURL)
        case .claudeWeb: return try ClaudeWebImport.scan(fileURL)
        }
    }
}

/// Codex's sessions, read from `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`.
///
/// Only session files and the title index are read. `auth.json` and everything else in
/// `~/.codex` stay untouched.
public enum CodexSessions {

    public static func home(paths: HostPaths = .current) -> URL {
        paths.home.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func conversations(paths: HostPaths = .current) -> [ExternalConversation] {
        let root = home(paths: paths)
        let titles = threadNames(root)
        guard let walker = FileManager.default.enumerator(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [ExternalConversation] = []
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let head = headOf(url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let title = titles[head.id] ?? head.firstPrompt.map { clip($0, 90) }
                ?? "Codex session" + (head.cwd.map { " in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "")
            found.append(ExternalConversation(source: .codex, id: head.id, fileURL: url, title: title,
                                              createdAt: head.started, updatedAt: modified ?? head.started ?? .distantPast,
                                              cwd: head.cwd, model: head.model))
        }
        return found
    }

    struct Head {
        let id: String
        let started: Date?
        let cwd: String?
        let model: String?
        let firstPrompt: String?
    }

    /// The session header and first real prompt, from the start of the file.
    static func headOf(_ url: URL) -> Head? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var id: String?, started: Date?, cwd: String?, model: String?, prompt: String?
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONValue.parse(Data(line)) else { continue }
            let payload = record["payload"]
            switch record["type"]?.stringValue {
            case "session_meta":
                id = payload?["id"]?.stringValue ?? payload?["session_id"]?.stringValue
                started = (payload?["timestamp"]?.stringValue ?? record["timestamp"]?.stringValue).flatMap(Transcript.parseTimestamp)
                cwd = payload?["cwd"]?.stringValue
            case "turn_context":
                model = model ?? payload?["model"]?.stringValue
            case "response_item" where prompt == nil:
                if let message = payload, let text = userText(message) { prompt = text }
            default:
                break
            }
            if id != nil, prompt != nil, model != nil { break }
        }
        guard let id else { return nil }
        return Head(id: id, started: started, cwd: cwd, model: model, firstPrompt: prompt)
    }

    /// `session_index.jsonl`: the names Codex shows for its threads.
    static func threadNames(_ root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONValue.parse(Data(line)), let id = record["id"]?.stringValue,
                  let name = record["thread_name"]?.stringValue, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    /// A user message's text, unless it's context Codex injected rather than something typed.
    static func userText(_ message: JSONValue) -> String? {
        guard message["type"]?.stringValue == "message", message["role"]?.stringValue == "user" else { return nil }
        let text = messageText(message)
        guard !text.isEmpty, !isInjected(text) else { return nil }
        return text
    }

    static func messageText(_ message: JSONValue) -> String {
        (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard let type = block["type"]?.stringValue, type.hasSuffix("text") else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInjected(_ text: String) -> Bool { InjectedContext.contains(text) }

    public static func scan(_ url: URL) throws -> TranscriptScan {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw TranscriptError.unreadable(url: url, underlying: String(describing: error))
        }
        var scan = TranscriptScan()
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONValue.parse(Data(line)) else { scan.malformedLines += 1; continue }
            let timestamp = record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp)
            if let timestamp {
                if scan.firstTimestamp == nil { scan.firstTimestamp = timestamp }
                scan.lastTimestamp = timestamp
            }
            let payload = record["payload"]
            switch (record["type"]?.stringValue, payload?["type"]?.stringValue) {
            case ("session_meta", _):
                scan.cwd = payload?["cwd"]?.stringValue
                scan.gitBranch = payload?["git"]?["branch"]?.stringValue
            case ("response_item", "message"):
                guard let payload, let role = payload["role"]?.stringValue else { continue }
                if role == "user" {
                    guard let text = userText(payload) else { continue }
                    scan.messages.append(.init(uuid: nil, role: .user, kind: .message, timestamp: timestamp, text: text))
                } else if role == "assistant" {
                    let text = messageText(payload)
                    guard !text.isEmpty else { continue }
                    scan.messages.append(.init(uuid: nil, role: .assistant, kind: .message, timestamp: timestamp, text: text))
                }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                if let name = payload?["name"]?.stringValue {
                    scan.toolCalls.append(.init(messageUUID: nil, timestamp: timestamp, name: name, filePath: nil))
                }
            default:
                continue
            }
        }
        scan.endOffset = Int64(data.count)
        return scan
    }

    static func clip(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
