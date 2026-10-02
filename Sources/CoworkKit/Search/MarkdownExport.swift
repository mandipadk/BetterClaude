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
        render(ReadableConversation(transcript: transcript), title: title, model: model, options: options)
    }

    /// What the reader shows, as Markdown: `assistantName` is who replied, Codex for a Codex
    /// conversation.
    public static func render(_ conversation: ReadableConversation,
                              title: String,
                              model: String? = nil,
                              assistantName: String = "Claude",
                              options: Options = Options()) -> String {
        var out = ""
        if options.includeFrontMatter {
            out += "# \(title)\n\n"
            var facts: [String] = []
            if let model, !model.isEmpty { facts.append(model) }
            facts.append(conversation.messageCount == 1 ? "1 message" : "\(conversation.messageCount) messages")
            if let first = conversation.firstTimestamp {
                facts.append(first.formatted(date: .abbreviated, time: .omitted))
            }
            out += facts.joined(separator: ", ") + "\n\n---\n\n"
        }

        func stamp(_ date: Date?) -> String {
            guard options.includeTimestamps, let date else { return "" }
            return "  \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        for entry in conversation.entries {
            switch entry {
            case .message(let message):
                let speaker: String
                switch message.role {
                case .user: speaker = "You"
                case .assistant: speaker = assistantName
                case .system: speaker = "System"
                case .tool: speaker = "Tool"
                case .unknown: speaker = "Note"
                }
                out += "## \(speaker)\(stamp(message.timestamp))\n\n"
                if !message.text.isEmpty { out += "\(message.text)\n\n" }
                for name in message.attachments { out += "_Attached: \(name)_\n\n" }
            case .tools(_, let names):
                guard options.includeToolActivity else { continue }
                var seen = Set<String>()
                let unique = names.filter { seen.insert($0).inserted }
                out += "_Used \(names.count == 1 ? names[0] : "\(names.count) tools: \(unique.joined(separator: ", "))")_\n\n"
            case .compaction(let compaction):
                out += "---\n\n_\(assistantName) compacted the conversation here._\n\n"
                if let summary = compaction.summary, !summary.isEmpty {
                    out += summary.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> \($0)" }.joined(separator: "\n") + "\n\n"
                }
            case .recap(_, let text, let timestamp):
                out += "## \(assistantName)'s recap\(stamp(timestamp))\n\n\(text)\n\n"
            case .notice(let notice):
                out += "_\(notice.text)_\n\n"
            }
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
