import Foundation

/// Renders a conversation as Markdown.
///
/// The transcript format carries a great deal that is meaningless outside Claude — tool
/// call ids, sidechain plumbing, queue bookkeeping. What survives here is what a person
/// would recognise as the conversation: who said what, in order, with the attachments named
/// rather than inlined.
public enum MarkdownExport {

    public struct Options: Sendable {
        public var includeTimestamps: Bool
        public var includeToolActivity: Bool
        /// Front matter is useful for archives and noise for a quick paste.
        public var includeFrontMatter: Bool

        public init(includeTimestamps: Bool = true,
                    includeToolActivity: Bool = false,
                    includeFrontMatter: Bool = true) {
            self.includeTimestamps = includeTimestamps
            self.includeToolActivity = includeToolActivity
            self.includeFrontMatter = includeFrontMatter
        }
    }

    public static func render(transcript: Transcript,
                              title: String,
                              model: String? = nil,
                              options: Options = Options()) -> String {
        var out = ""
        let stats = transcript.stats()

        if options.includeFrontMatter {
            out += "# \(title)\n\n"
            var facts: [String] = []
            if let model { facts.append(model) }
            facts.append("\(stats.userTurns + stats.assistantTurns) messages")
            if let first = stats.firstTimestamp {
                facts.append(first.formatted(date: .abbreviated, time: .omitted))
            }
            out += facts.joined(separator: " · ") + "\n\n---\n\n"
        }

        let messages = ConversationText.messages(in: transcript,
                                                 includeToolResults: options.includeToolActivity)
        for message in messages {
            let speaker: String
            switch message.role {
            case .user: speaker = "You"
            case .assistant: speaker = "Claude"
            case .system: speaker = "System"
            case .tool: speaker = "Tool"
            case .unknown: speaker = "—"
            }

            out += "## \(speaker)"
            if options.includeTimestamps, let stamp = message.timestamp {
                out += "  \(stamp.formatted(date: .abbreviated, time: .shortened))"
            }
            out += "\n\n\(message.text)\n\n"
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A filename that is safe on macOS and still recognisable.
    public static func suggestedFileName(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "conversation" : String(cleaned.prefix(80))
        return "\(base).md"
    }
}
