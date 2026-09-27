import Foundation

/// A conversation as a person reads it: what each side said, in order, with the tool work in
/// between folded into one line per stretch ("Used 3 tools") instead of dozens of records.
public struct ReadableConversation: Sendable {
    public enum Entry: Sendable, Identifiable {
        case message(MessageText)
        /// Consecutive tool calls between two messages, by tool name in call order.
        case tools(id: String, names: [String])

        public var id: String {
            switch self {
            case .message(let message): return message.id
            case .tools(let id, _): return id
            }
        }
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
