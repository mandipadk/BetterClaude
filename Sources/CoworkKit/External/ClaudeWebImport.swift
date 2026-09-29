import Foundation

/// claude.ai conversations, from the data export claude.ai sends by email (Settings, Privacy,
/// Export data).
///
/// Importing reads `conversations.json` from the export and keeps each conversation as a
/// small file of its own in Better Claude's folder, so they sit in the timeline beside
/// everything else, searchable and readable. The export itself is left as it was.
public enum ClaudeWebImport {

    public static func root(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Imports/claude.ai", isDirectory: true)
    }

    static func indexURL(paths: HostPaths) -> URL { root(paths: paths).appendingPathComponent("index.json") }

    public struct Report: Sendable, Equatable {
        public var added = 0
        public var updated = 0
        public var unchanged = 0
        public var skipped = 0
    }

    public enum ImportError: Error, CustomStringConvertible {
        case notAnExport
        case unreadable(String)
        public var description: String {
            switch self {
            case .notAnExport: return "That isn't a claude.ai export: it has no conversations.json."
            case .unreadable(let why): return "Couldn't read the export: \(why)"
            }
        }
    }

    struct IndexEntry: Codable, Equatable {
        let uuid: String
        let name: String
        let createdAt: Date?
        let updatedAt: Date
        let account: String?
        let file: String
        let messageCount: Int
    }

    /// Imports an export: the `.zip` claude.ai sends, the folder it unpacks to, or its
    /// `conversations.json`.
    @discardableResult
    public static func importExport(at url: URL, paths: HostPaths = .current) throws -> Report {
        let json = try conversationsFile(in: url)
        defer { if json.temporary { try? FileManager.default.removeItem(at: json.cleanup) } }
        let value: JSONValue
        do { value = try JSONValue.parse(try Data(contentsOf: json.url, options: .mappedIfSafe)) } catch {
            throw ImportError.unreadable(String(describing: error))
        }
        guard let conversations = value.arrayValue else { throw ImportError.notAnExport }

        let folder = root(paths: paths)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index = Dictionary(loadIndex(paths: paths).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var report = Report()
        for conversation in conversations {
            guard let uuid = conversation["uuid"]?.stringValue else { report.skipped += 1; continue }
            let messages = (conversation["chat_messages"]?.arrayValue ?? []).compactMap(normalize)
            let updated = conversation["updated_at"]?.stringValue.flatMap(Transcript.parseTimestamp)
                ?? messages.compactMap { $0["created_at"]?.stringValue.flatMap(Transcript.parseTimestamp) }.max() ?? Date()
            let account = conversation["account"]?["uuid"]?.stringValue
            let name = conversation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? messages.first.flatMap { $0["text"]?.stringValue }.map { CodexSessions.clip($0, 80) } ?? "Untitled"
            if let existing = index[uuid], existing.updatedAt >= updated, existing.messageCount == messages.count {
                report.unchanged += 1
                continue
            }
            let record = JSONValue.object(JSONObject([
                ("uuid", .string(uuid)), ("name", .string(name)),
                ("created_at", conversation["created_at"] ?? .null), ("updated_at", conversation["updated_at"] ?? .null),
                ("account", account.map(JSONValue.string) ?? .null),
                ("messages", .array(messages)),
            ]))
            let file = "\(safe(uuid)).json"
            try AtomicWrite.write(record.serialized(), to: folder.appendingPathComponent(file))
            if index[uuid] == nil { report.added += 1 } else { report.updated += 1 }
            index[uuid] = IndexEntry(uuid: uuid, name: name,
                                     createdAt: conversation["created_at"]?.stringValue.flatMap(Transcript.parseTimestamp),
                                     updatedAt: updated, account: account, file: file, messageCount: messages.count)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AtomicWrite.write(try encoder.encode(index.values.sorted { $0.updatedAt > $1.updatedAt }),
                              to: indexURL(paths: paths))
        return report
    }

    /// One message, kept as: who, when, and its text (with any attached document's text).
    static func normalize(_ message: JSONValue) -> JSONValue? {
        let sender = message["sender"]?.stringValue ?? ""
        var pieces: [String] = []
        if let blocks = message["content"]?.arrayValue, !blocks.isEmpty {
            for block in blocks where block["type"]?.stringValue == "text" {
                if let text = block["text"]?.stringValue, !text.isEmpty { pieces.append(text) }
            }
        }
        if pieces.isEmpty, let text = message["text"]?.stringValue, !text.isEmpty { pieces.append(text) }
        for attachment in message["attachments"]?.arrayValue ?? [] {
            let name = attachment["file_name"]?.stringValue ?? "attachment"
            if let content = attachment["extracted_content"]?.stringValue, !content.isEmpty {
                pieces.append("[Attached \(name)]\n\(content)")
            } else {
                pieces.append("[Attached \(name)]")
            }
        }
        let text = pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .object(JSONObject([
            ("uuid", message["uuid"] ?? .null),
            ("sender", .string(sender == "human" ? "user" : sender == "assistant" ? "assistant" : sender)),
            ("created_at", message["created_at"] ?? .null),
            ("text", .string(text)),
        ]))
    }

    struct Located {
        let url: URL
        let temporary: Bool
        let cleanup: URL
    }

    static func conversationsFile(in url: URL) throws -> Located {
        let fm = FileManager.default
        if url.lastPathComponent == "conversations.json" { return Located(url: url, temporary: false, cleanup: url) }
        if Discovery.isDirectory(url) {
            let candidate = url.appendingPathComponent("conversations.json")
            guard fm.fileExists(atPath: candidate.path) else { throw ImportError.notAnExport }
            return Located(url: candidate, temporary: false, cleanup: candidate)
        }
        guard url.pathExtension.lowercased() == "zip" else { throw ImportError.notAnExport }
        let temporary = fm.temporaryDirectory.appendingPathComponent("claude-export-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.unreadable("the zip couldn't be opened") }
        // The export may be wrapped in a folder of its own.
        let direct = temporary.appendingPathComponent("conversations.json")
        if fm.fileExists(atPath: direct.path) { return Located(url: direct, temporary: true, cleanup: temporary) }
        let nested = ((try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("conversations.json") }
            .first { fm.fileExists(atPath: $0.path) }
        guard let nested else {
            try? fm.removeItem(at: temporary)
            throw ImportError.notAnExport
        }
        return Located(url: nested, temporary: true, cleanup: temporary)
    }

    static func loadIndex(paths: HostPaths) -> [IndexEntry] {
        guard let data = try? Data(contentsOf: indexURL(paths: paths)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IndexEntry].self, from: data)) ?? []
    }

    /// Imported conversations, with the account each belongs to.
    public static func conversations(paths: HostPaths = .current) -> [(ExternalConversation, account: String?)] {
        let folder = root(paths: paths)
        return loadIndex(paths: paths).map { entry in
            (ExternalConversation(source: .claudeWeb, id: entry.uuid, fileURL: folder.appendingPathComponent(entry.file),
                                  title: entry.name, createdAt: entry.createdAt, updatedAt: entry.updatedAt,
                                  cwd: nil, model: nil), entry.account)
        }
    }

    /// Forgets every imported conversation. The export they came from isn't touched.
    public static func removeAll(paths: HostPaths = .current) throws {
        let folder = root(paths: paths)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    public static func scan(_ url: URL) throws -> TranscriptScan {
        let value: JSONValue
        do { value = try JSONValue.parse(try Data(contentsOf: url)) } catch {
            throw TranscriptError.unreadable(url: url, underlying: String(describing: error))
        }
        var scan = TranscriptScan()
        for message in value["messages"]?.arrayValue ?? [] {
            guard let text = message["text"]?.stringValue else { continue }
            let timestamp = message["created_at"]?.stringValue.flatMap(Transcript.parseTimestamp)
            if let timestamp {
                if scan.firstTimestamp == nil { scan.firstTimestamp = timestamp }
                scan.lastTimestamp = timestamp
            }
            let role: MessageText.Role = message["sender"]?.stringValue == "user" ? .user : .assistant
            scan.messages.append(.init(uuid: message["uuid"]?.stringValue, role: role, kind: .message,
                                       timestamp: timestamp, text: text))
        }
        scan.title = value["name"]?.stringValue
        return scan
    }

    static func safe(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }
}
