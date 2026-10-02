import Foundation

/// Gathers what a model needs to answer a question about past conversations: the few most
/// relevant conversations, the passages that matched, and Claude's own recaps of them —
/// numbered, so the answer can cite them.
public enum AskRetrieval {

    public struct Source: Sendable, Identifiable, Equatable {
        public var id: String { conversationID }
        /// The number the answer cites it by, from 1.
        public let number: Int
        public let conversationID: String
        public let sessionID: String?
        public let title: String
        public let place: String
        public let lastActivity: Date?
        public let passages: [String]
    }

    /// Words that carry no meaning for a search, in the way people phrase questions.
    static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "before", "being", "both", "but", "by", "can", "could", "did", "do", "does", "doing",
        "done", "for", "from", "had", "has", "have", "having", "he", "her", "here", "him", "his", "how", "i",
        "if", "in", "into", "is", "it", "its", "just", "last", "me", "more", "most", "my", "no", "not", "now",
        "of", "on", "once", "one", "only", "or", "other", "our", "out", "over", "said", "same", "she", "should",
        "so", "some", "such", "tell", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "through", "time", "to", "too", "under", "until", "up", "us", "very", "was", "we",
        "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would",
        "you", "your", "claude", "decide", "decided", "remember", "discuss", "discussed", "talk", "talked",
        "ever", "previously", "earlier", "ago", "week", "month", "yesterday", "today", "get", "got", "use", "used",
        "let", "lets", "make", "made", "way", "thing", "things", "anything", "something", "know",
    ]

    /// The words of a question worth searching for.
    public static func keywords(in question: String) -> [String] {
        var seen = Set<String>()
        return HistorySearch.terms(in: question).filter { word in
            guard word.count > 1, !stopWords.contains(word), !seen.contains(word) else { return false }
            seen.insert(word)
            return true
        }
    }

    /// The sources for `question`, and the numbered text to hand the model, kept under
    /// `budget` characters so it fits a small context window alongside the answer.
    public static func gather(question: String, index: HistoryIndex, accountIDs: Set<String>? = nil,
                              maxSources: Int = 6, budget: Int = 9_000) async throws -> (sources: [Source], context: String) {
        let words = keywords(in: question)
        guard !words.isEmpty else { return ([], "") }
        // Only conversations still listed: a source is there to be opened.
        var options = HistorySearch.Options(accountIDs: accountIDs, includeAbsent: false,
                                            limit: maxSources, excerptsPerHit: 3)
        options.requireAllWords = false
        options.redactSecrets = true
        options.limit = maxSources * 2
        // A conversation sharing one common word with the question is noise; keep the ones
        // with at least half its words, and always the best one.
        let found = try await index.search(words.joined(separator: " "), options: options)
        let hits = found.enumerated().filter { $0.offset == 0 || $0.element.coverage >= 0.5 }
            .map(\.element).prefix(maxSources)

        var sources: [Source] = []
        var context = ""
        let perSource = max(600, budget / max(1, hits.count))
        for hit in hits {
            let number = sources.count + 1
            var passages = hit.excerpts.map(\.text)
            let recap = try await index.rows("""
                SELECT text FROM messages WHERE conversation_id = ? AND kind IN ('recap', 'compaction')
                ORDER BY ordinal DESC LIMIT 1
                """, [.text(hit.conversationID)]).first?.text(0)
            if let recap { passages.append("Claude's recap: " + clip(SecretSweep.redact(recap), 500)) }

            var block = "[\(number)] \(hit.title) (\(hit.place)"
            if let date = hit.lastActivity { block += ", \(date.formatted(.dateTime.day().month().year()))" }
            block += ")\n"
            for passage in passages {
                let line = "- \(clip(passage, 500))\n"
                if block.count + line.count > perSource { break }
                block += line
            }
            guard context.count + block.count <= budget else { break }
            context += block + "\n"
            sources.append(Source(number: number, conversationID: hit.conversationID, sessionID: hit.sessionID,
                                  title: hit.title, place: hit.place, lastActivity: hit.lastActivity,
                                  passages: passages))
        }
        return (sources, context)
    }

    /// What the model is told, before every question.
    public static let instructions = """
    You answer questions about the person's past conversations with Claude, using only the \
    numbered excerpts you are given. Cite the excerpts you rely on by number in square brackets, \
    like [2]. Quote short phrases where the exact words matter. If the excerpts don't answer the \
    question, say so plainly in one sentence and suggest other words to search for. Keep answers \
    to a few sentences. Address the person as "you".
    """

    /// The source numbers an answer cites: `[2]`, `[1, 3]` and `[1-3]` alike.
    public static func citedNumbers(in answer: String) -> Set<Int> {
        var cited = Set<Int>()
        for group in answer.matches(of: /\[([0-9,\-–\s]+)\]/) {
            var numbers = Set<Int>()
            for piece in group.output.1.split(separator: ",") {
                let ends = piece.split(whereSeparator: { $0 == "-" || $0 == "–" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if ends.count == 1, let number = Int(ends[0]) {
                    numbers.insert(number)
                } else if ends.count == 2, let low = Int(ends[0]), let high = Int(ends[1]), low <= high, high - low < 50 {
                    numbers.formUnion(low...high)
                } else {
                    numbers = []
                    break
                }
            }
            cited.formUnion(numbers)
        }
        return cited
    }

    public static func prompt(question: String, context: String) -> String {
        "Excerpts from past conversations:\n\n\(context)\nQuestion: \(question)"
    }

    static func clip(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
