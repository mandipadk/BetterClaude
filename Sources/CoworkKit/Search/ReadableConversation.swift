import Foundation

/// A conversation as a person reads it: what each side said, in order, with the tool work in
/// between folded into one line per stretch ("Used 3 tools") instead of dozens of records.
public struct ReadableConversation: Sendable {
    public enum Entry: Sendable, Identifiable {
        case message(MessageText)
        /// Consecutive tool calls between two messages, by tool name in call order.
        case tools(id: String, names: [String])
        /// Where Claude compacted the conversation: everything before is what it no longer
        /// sees, and `summary` is what it kept of it.
        case compaction(Compaction)
        /// A short recap Claude wrote when the person stepped away.
        case recap(id: String, text: String, timestamp: Date?)

        public var id: String {
            switch self {
            case .message(let message): return message.id
            case .tools(let id, _): return id
            case .compaction(let compaction): return compaction.id
            case .recap(let id, _, _): return id
            }
        }
    }

    public struct Compaction: Sendable, Equatable {
        public let id: String
        public let timestamp: Date?
        /// `auto` when Claude ran out of room, `manual` when someone ran /compact.
        public let trigger: String?
        public let tokensBefore: Int?
        public let tokensAfter: Int?
        public var summary: String?
    }

    public let entries: [Entry]
    /// The model that answered most recently, as recorded in the transcript.
    public let model: String?
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?

    public var messageCount: Int {
        entries.reduce(0) { count, entry in
            if case .message = entry { return count + 1 }
            return count
        }
    }

    /// A conversation from outside Claude's apps, from its scanned messages.
    public init(scan: TranscriptScan, model: String?) {
        entries = scan.messages.enumerated().map { index, message in
            .message(MessageText(id: message.uuid ?? "m\(index)", role: message.role, text: message.text,
                                 timestamp: message.timestamp, index: index))
        }
        self.model = model
        firstTimestamp = scan.firstTimestamp
        lastTimestamp = scan.lastTimestamp
    }

    public init(transcript: Transcript) {
        var entries: [Entry] = []
        var pendingTools: [String] = []
        var pendingID: String?
        var model: String?
        var first: Date?
        var last: Date?

        func flushTools() {
            guard !pendingTools.isEmpty, let id = pendingID else { return }
            entries.append(.tools(id: "tools-" + id, names: pendingTools))
            pendingTools = []
            pendingID = nil
        }

        for (index, record) in transcript.records.enumerated() {
            if record["type"]?.stringValue == "system" {
                let stamp = record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp)
                switch record["subtype"]?.stringValue {
                case "compact_boundary":
                    flushTools()
                    let metadata = record["compactMetadata"]
                    entries.append(.compaction(Compaction(
                        id: record["uuid"]?.stringValue ?? "compaction-\(index)", timestamp: stamp,
                        trigger: metadata?["trigger"]?.stringValue,
                        tokensBefore: metadata?["preTokens"]?.intValue.map(Int.init),
                        tokensAfter: metadata?["postTokens"]?.intValue.map(Int.init), summary: nil)))
                case "away_summary":
                    if let text = record["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        flushTools()
                        entries.append(.recap(id: record["uuid"]?.stringValue ?? "recap-\(index)", text: text, timestamp: stamp))
                    }
                default:
                    break
                }
                continue
            }
            // The summary written at a compaction belongs to it, not to the person.
            if record["isCompactSummary"]?.boolValue == true, let message = record["message"] {
                let text = ConversationText.plainText(of: message)
                if let last = entries.lastIndex(where: { if case .compaction = $0 { return true }; return false }),
                   case .compaction(var compaction) = entries[last], compaction.summary == nil {
                    compaction.summary = text
                    entries[last] = .compaction(compaction)
                } else if !text.isEmpty {
                    entries.append(.compaction(Compaction(id: record["uuid"]?.stringValue ?? "summary-\(index)",
                                                          timestamp: nil, trigger: nil, tokensBefore: nil,
                                                          tokensAfter: nil, summary: text)))
                }
                continue
            }
            guard let type = record["type"]?.stringValue, type == "user" || type == "assistant",
                  record["isMeta"]?.boolValue != true,
                  let message = record["message"] else { continue }

            if let stamp = record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp) {
                if first == nil { first = stamp }
                last = stamp
            }
            if type == "assistant", let name = message["model"]?.stringValue, name.hasPrefix("claude") {
                model = name
            }

            for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                if pendingID == nil { pendingID = record["uuid"]?.stringValue ?? "\(index)" }
                pendingTools.append(block["name"]?.stringValue ?? "Tool")
            }

            let text = ConversationText.plainText(of: message)
            guard !text.isEmpty else { continue }
            flushTools()
            entries.append(.message(MessageText(
                id: record["uuid"]?.stringValue ?? "\(index)",
                role: type == "user" ? .user : .assistant,
                text: text,
                timestamp: record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp),
                index: index)))
        }
        flushTools()

        self.entries = entries
        self.model = model
        self.firstTimestamp = first
        self.lastTimestamp = last
    }
}
