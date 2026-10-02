import Foundation

/// Whether the reader shows everything a transcript holds that a person would want to see:
/// every compaction, every recap, every prompt someone typed. Counts only; nothing is printed
/// from the conversation itself.
public enum ReaderCheck {

    public struct Result: Sendable, Equatable {
        public var compactions = 0, compactionsShown = 0
        public var recaps = 0, recapsShown = 0
        public var prompts = 0, promptsShown = 0
        public var rewound = 0

        public init(compactions: Int = 0, compactionsShown: Int = 0, recaps: Int = 0, recapsShown: Int = 0,
                    prompts: Int = 0, promptsShown: Int = 0, rewound: Int = 0) {
            self.compactions = compactions; self.compactionsShown = compactionsShown
            self.recaps = recaps; self.recapsShown = recapsShown
            self.prompts = prompts; self.promptsShown = promptsShown
            self.rewound = rewound
        }

        public var isComplete: Bool {
            compactionsShown >= compactions && recapsShown >= recaps && promptsShown >= prompts
        }

        public static func + (a: Result, b: Result) -> Result {
            Result(compactions: a.compactions + b.compactions, compactionsShown: a.compactionsShown + b.compactionsShown,
                   recaps: a.recaps + b.recaps, recapsShown: a.recapsShown + b.recapsShown,
                   prompts: a.prompts + b.prompts, promptsShown: a.promptsShown + b.promptsShown,
                   rewound: a.rewound + b.rewound)
        }
    }

    /// Compares what the file holds with what ReadableConversation shows. Prompts are judged by
    /// a rule of their own, independent of the reader's: text left over once complete
    /// `<tag>…</tag>` blocks are removed. A prompt can be missing because it sat on a rewound
    /// attempt, which the reader folds into one line; `rewound` says how many such lines there are.
    public static func check(_ transcript: Transcript) -> Result {
        var result = Result()
        var promptIDs: [String] = []
        var seen = Set<String>()
        for record in transcript.records {
            switch record["type"]?.stringValue {
            case "system":
                switch record["subtype"]?.stringValue {
                case "compact_boundary": result.compactions += 1
                case "away_summary": result.recaps += 1
                default: break
                }
            case "user":
                guard record["isMeta"]?.boolValue != true, record["isCompactSummary"]?.boolValue != true,
                      record["isSidechain"]?.boolValue != true,
                      let uuid = record["uuid"]?.stringValue, seen.insert(uuid).inserted,
                      let message = record["message"], typed(message) else { continue }
                promptIDs.append(uuid)
            default:
                break
            }
        }
        result.prompts = promptIDs.count

        let readable = ReadableConversation(transcript: transcript)
        var shown = Set<String>()
        for entry in readable.entries {
            switch entry {
            case .compaction: result.compactionsShown += 1
            case .recap: result.recapsShown += 1
            case .message(let message) where message.role == .user: shown.insert(String(message.id.prefix(36)))
            case .notice(let notice) where notice.kind == .rewound: result.rewound += 1
            case .notice(let notice): shown.insert(String(notice.id.prefix(36)))
            default: break
            }
        }
        result.promptsShown = promptIDs.filter { shown.contains($0) }.count
        return result
    }

    /// Whether a user message holds something a person did: text outside complete tag blocks,
    /// or an attachment. The line Claude Code writes when a reply is stopped isn't typed.
    static func typed(_ message: JSONValue) -> Bool {
        var texts: [String] = []
        if let text = message["content"]?.stringValue { texts.append(text) }
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": if let text = block["text"]?.stringValue { texts.append(text) }
            case "image", "document": return true
            default: continue
            }
        }
        return texts.contains { text in
            let rest = outsideClosedTags(text)
            return !rest.isEmpty && !rest.hasPrefix("[Request interrupted by user")
        }
    }

    /// The text with every complete `<name …>…</name>` block removed, trimmed.
    static func outsideClosedTags(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"<([a-zA-Z][\w-]*)(\s[^>]*)?>[\s\S]*?</\1>"#) else { return text }
        let stripped = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
