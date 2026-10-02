import Foundation

/// One message flattened to plain text, with enough provenance to jump back to it.
public struct MessageText: Sendable, Identifiable {
    public enum Role: String, Sendable {
        case user, assistant, system, tool, unknown
    }

    public let id: String
    public let role: Role
    public let text: String
    public let timestamp: Date?
    /// Position in the transcript, used to order results within one conversation.
    public let index: Int
    /// What the person attached, by name: "Image", or a document's title.
    public let attachments: [String]

    public init(id: String, role: Role, text: String, timestamp: Date?, index: Int, attachments: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.index = index
        self.attachments = attachments
    }
}

/// Flattens a transcript into readable messages.
///
/// A transcript record's `content` is either a plain string or an array of typed blocks, and
/// the block vocabulary keeps growing. Anything unrecognised is skipped rather than rendered
/// as raw JSON — a search index full of `{"type":"tool_use","id":"toolu_…"}` is worse than
/// one that omits it.
public enum ConversationText {

    /// Blocks that carry prose a person actually wrote or read.
    private static let textualBlockTypes: Set<String> = ["text"]

    public static func messages(in transcript: Transcript,
                                includeToolResults: Bool = false) -> [MessageText] {
        var out: [MessageText] = []
        out.reserveCapacity(transcript.records.count)

        for (index, record) in transcript.records.enumerated() {
            guard let type = record["type"]?.stringValue else { continue }
            let role: MessageText.Role
            switch type {
            case "user": role = .user
            case "assistant": role = .assistant
            case "system": role = .system
            default: continue
            }
            // Meta records are harness bookkeeping injected into the conversation, not
            // anything the person said.
            if record["isMeta"]?.boolValue == true { continue }
            guard let message = record["message"] else { continue }

            let text = plainText(of: message, includeToolResults: includeToolResults)
            guard !text.isEmpty else { continue }

            out.append(MessageText(
                id: record["uuid"]?.stringValue ?? "\(index)",
                role: role,
                text: text,
                timestamp: record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp),
                index: index))
        }
        return out
    }

    /// The text blocks of one `message` value, in order; string content is one block.
    public static func textBlocks(of message: JSONValue) -> [String] {
        guard let content = message["content"] else { return [] }
        if let direct = content.stringValue { return [direct] }
        return (content.arrayValue ?? []).compactMap { block in
            if let raw = block.stringValue { return raw }
            guard let type = block["type"]?.stringValue, textualBlockTypes.contains(type) else { return nil }
            return block["text"]?.stringValue
        }
    }

    /// Images and documents attached to one `message` value, by name.
    public static func attachmentNames(of message: JSONValue) -> [String] {
        (message["content"]?.arrayValue ?? []).compactMap { block in
            switch block["type"]?.stringValue {
            case "image": return "Image"
            case "document":
                let name = block["title"]?.stringValue ?? block["source"]?["file_name"]?.stringValue
                return name.flatMap { $0.isEmpty ? nil : $0 } ?? "Document"
            default: return nil
            }
        }
    }

    /// The prose inside one `message` value.
    public static func plainText(of message: JSONValue, includeToolResults: Bool = false) -> String {
        guard let content = message["content"] else { return "" }
        if let direct = content.stringValue {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = content.arrayValue else { return "" }

        var pieces: [String] = []
        for block in blocks {
            guard let type = block["type"]?.stringValue else {
                if let raw = block.stringValue { pieces.append(raw) }
                continue
            }
            if textualBlockTypes.contains(type), let text = block["text"]?.stringValue {
                pieces.append(text)
            } else if type == "tool_result", includeToolResults {
                pieces.append(plainText(of: block, includeToolResults: true))
            }
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
