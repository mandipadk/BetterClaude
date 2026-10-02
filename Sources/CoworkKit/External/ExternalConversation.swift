import Foundation

/// A conversation from outside Claude's own apps: claude.ai, from its data export, or Codex.
/// Read only; Better Claude never writes to where these came from.
public struct ExternalConversation: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// Conversations from claude.ai, imported from its data export.
        case claudeWeb
        case codex
        /// Kept conversations from another Mac, opened from its backup.
        case otherMac

        public var name: String {
            switch self {
            case .claudeWeb: return "claude.ai"
            case .codex: return "Codex"
            case .otherMac: return "Another Mac"
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
        case .otherMac: return try TranscriptScanner.scan(fileURL)
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

    /// What a session file is. Codex writes one for every thread, and most of them aren't a
    /// conversation a person had.
    public enum Kind: String, Sendable, Hashable {
        /// Started by a person in one of Codex's own apps.
        case conversation
        /// A thread Codex started for a conversation: a sub-agent, or a fork it made to run one.
        case subagent
        /// Codex's automatic review of a command it wanted to run.
        case review
        /// Started by another program driving Codex.
        case automated
    }

    /// The clients a person types into. Anything else driving Codex is a program.
    static let interactiveOriginators: Set<String> = [
        "Codex Desktop", "codex-tui", "codex_cli_rs", "codex_vscode", "codex_exec", "codex-cli",
    ]

    /// How many session files of each kind there are, and which programs ran the automated ones.
    public struct Survey: Sendable, Equatable {
        public var counts: [Kind: Int] = [:]
        public var automatedBy: [String: Int] = [:]
    }

    public static func survey(paths: HostPaths = .current) -> Survey {
        var survey = Survey()
        for url in sessionFiles(paths: paths) {
            guard let head = headOf(url) else { continue }
            survey.counts[head.kind, default: 0] += 1
            if head.kind == .automated { survey.automatedBy[head.originator ?? "another program", default: 0] += 1 }
        }
        return survey
    }

    static func sessionFiles(paths: HostPaths) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: home(paths: paths).appendingPathComponent("sessions", isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// Conversations people had in Codex. Sub-agents, automatic reviews and runs by other
    /// programs are left out; ``survey(paths:)`` counts them.
    public static func conversations(paths: HostPaths = .current) -> [ExternalConversation] {
        let root = home(paths: paths)
        let titles = threadNames(root)
        var found: [ExternalConversation] = []
        for url in sessionFiles(paths: paths) {
            guard let head = headOf(url), head.kind == .conversation else { continue }
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
        var originator: String? = nil
        var kind: Kind = .conversation
        var parentID: String? = nil
        var nickname: String? = nil
        var role: String? = nil
    }

    /// A thread Codex started while a conversation ran.
    public struct Subagent: Sendable, Hashable, Identifiable {
        public let id: String
        /// The conversation it ran for, even when another sub-agent started it.
        public let conversationID: String
        public let nickname: String?
        public let role: String?
        public let started: Date?
        public let fileURL: URL
    }

    /// Sub-agents by the conversation they ran for.
    public static func subagents(paths: HostPaths = .current) -> [String: [Subagent]] {
        var heads: [String: (Head, URL)] = [:]
        for url in sessionFiles(paths: paths) {
            if let head = headOf(url) { heads[head.id] = (head, url) }
        }
        func conversation(of id: String) -> String? {
            var current = id
            for _ in 0..<16 {
                guard let (head, _) = heads[current] else { return nil }
                if head.kind == .conversation { return head.id }
                guard let parent = head.parentID else { return nil }
                current = parent
            }
            return nil
        }
        var result: [String: [Subagent]] = [:]
        for (head, url) in heads.values where head.kind == .subagent {
            guard let owner = head.parentID.flatMap(conversation(of:)) else { continue }
            result[owner, default: []].append(Subagent(id: head.id, conversationID: owner, nickname: head.nickname,
                                                       role: head.role, started: head.started, fileURL: url))
        }
        for key in result.keys { result[key]?.sort { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) } }
        return result
    }

    /// Reads `session_meta`: `source` is a string for a thread a client started, or
    /// `{"subagent": {"thread_spawn": …}}` / `{"subagent": {"other": "guardian"}}` for ones Codex
    /// started itself; `thread_source` says the same in newer versions.
    static func kind(source: JSONValue?, threadSource: String?, originator: String?, model: String?) -> Kind {
        if threadSource == "guardian_review" || model == "codex-auto-review" { return .review }
        if let subagent = source?["subagent"] {
            return subagent["other"]?.stringValue == "guardian" ? .review : .subagent
        }
        if threadSource == "subagent" { return .subagent }
        if let originator, !interactiveOriginators.contains(originator) { return .automated }
        return .conversation
    }

    /// Headers already read, by file, kept while the file is unchanged: a refresh every couple
    /// of seconds would otherwise re-read every session's start.
    private static let headCache = HeadCache()

    final class HeadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (size: Int, modified: Date, head: Head?)] = [:]

        func head(for url: URL, read: (URL) -> Head?) -> Head? {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate ?? .distantPast
            lock.lock()
            if let cached = entries[url.path], cached.size == size, cached.modified == modified {
                lock.unlock()
                return cached.head
            }
            lock.unlock()
            let head = read(url)
            lock.lock()
            entries[url.path] = (size, modified, head)
            lock.unlock()
            return head
        }
    }

    /// The session header and first real prompt, from the start of the file.
    static func headOf(_ url: URL) -> Head? {
        headCache.head(for: url, read: readHead)
    }

    static func readHead(_ url: URL) -> Head? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var id: String?, started: Date?, cwd: String?, model: String?, prompt: String?
        var source: JSONValue?, threadSource: String?, originator: String?
        var parentID: String?, nickname: String?, role: String?
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONValue.parse(Data(line)) else { continue }
            let payload = record["payload"]
            switch record["type"]?.stringValue {
            // A fork's file carries a copy of its parent's header further down; the first is its own.
            case "session_meta" where id == nil:
                id = payload?["id"]?.stringValue ?? payload?["session_id"]?.stringValue
                started = (payload?["timestamp"]?.stringValue ?? record["timestamp"]?.stringValue).flatMap(Transcript.parseTimestamp)
                cwd = payload?["cwd"]?.stringValue
                source = payload?["source"]
                threadSource = payload?["thread_source"]?.stringValue
                originator = payload?["originator"]?.stringValue
                let spawn = payload?["source"]?["subagent"]?["thread_spawn"]
                parentID = spawn?["parent_thread_id"]?.stringValue ?? payload?["parent_thread_id"]?.stringValue
                    ?? payload?["forked_from_id"]?.stringValue
                nickname = spawn?["agent_nickname"]?.stringValue ?? payload?["agent_nickname"]?.stringValue
                role = spawn?["agent_role"]?.stringValue ?? payload?["agent_role"]?.stringValue
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
        return Head(id: id, started: started, cwd: cwd, model: model, firstPrompt: prompt, originator: originator,
                    kind: kind(source: source, threadSource: threadSource, originator: originator, model: model),
                    parentID: parentID, nickname: nickname, role: role)
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
        let blocks = (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard let type = block["type"]?.stringValue, type.hasSuffix("text") else { return nil }
            return block["text"]?.stringValue
        }
        return InjectedContext.typedText(InjectedContext.parts(ofBlocks: blocks))
    }

    static func messageText(_ message: JSONValue) -> String {
        (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard let type = block["type"]?.stringValue, type.hasSuffix("text") else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            case ("session_meta", _) where scan.cwd == nil:
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
