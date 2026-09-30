import Foundation

/// What a compaction left out: the things you told Claude before it — constraints, corrections,
/// decisions — that its summary no longer mentions. After a compaction, the summary is all
/// Claude has of them.
public enum CompactionGaps {

    public struct Item: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case instruction, correction, decision }
        public var id: String { "\(ordinal)#\(text)" }
        public let text: String
        public let kind: Kind
        public let ordinal: Int
        public let timestamp: Date?
    }

    public struct Gap: Sendable, Equatable {
        /// Which compaction of the conversation, first is 0.
        public let compaction: Int
        public let at: Date?
        public let forgotten: [Item]
        /// How many things were checked, remembered or not.
        public let checked: Int
    }

    /// Words that make a sentence an instruction that should outlast the turn.
    static let instructionMarkers = ["don't", "dont", "do not", "never", "always", "must", "make sure", "only use",
                                     "avoid", "shouldn't", "should not", "remember", "keep ", "no need to", "stick to"]

    static func instructions(in text: String) -> [(String, Item.Kind)] {
        let decisions = Set(Decisions.sentences(in: text, role: "user", kind: "message").map(\.0))
        let isCorrection = Corrections.isCorrection(text)
        var found: [(String, Item.Kind)] = []
        var first = true
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            let clean = (sentence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { if !clean.isEmpty { first = false } }
            let lower = clean.lowercased()
            guard (15...240).contains(clean.count), !clean.hasSuffix("?"), !clean.contains("\n"),
                  !found.contains(where: { $0.0 == clean }) else { return }
            if first && isCorrection {
                found.append((clean, .correction))
            } else if decisions.contains(clean) {
                found.append((clean, .decision))
            } else if instructionMarkers.contains(where: { lower.contains($0) }) {
                found.append((clean, .instruction))
            }
        }
        return found
    }

    /// Whether the summary still carries it: most of the words that make it what it is.
    static func remembered(_ item: String, in summaryTerms: Set<String>) -> Bool {
        let terms = Corrections.terms(item)
        guard !terms.isEmpty else { return true }
        return Double(terms.intersection(summaryTerms).count) / Double(terms.count) >= 0.5
    }

    public static func gaps(conversationID: String, index: HistoryIndex) async throws -> [Gap] {
        let rows = try await index.rows("""
            SELECT ordinal, role, kind, text, timestamp FROM messages WHERE conversation_id = ? ORDER BY ordinal
            """, [.text(conversationID)])
        var gaps: [Gap] = []
        var pending: [Item] = []
        var carried: [Item] = []
        for row in rows {
            guard let text = row.text(3) else { continue }
            let ordinal = Int(row.int(0))
            if row.text(2) == "compaction" {
                // Everything said since the start still has to be in this summary: an earlier
                // summary that kept it is gone too.
                let summary = Corrections.terms(text).union(Set(PromptLibrary.normalize(text).split(separator: " ").map(String.init)))
                let candidates = carried + pending
                let forgotten = candidates.filter { !remembered($0.text, in: summary) }
                gaps.append(Gap(compaction: gaps.count, at: row.date(4), forgotten: forgotten, checked: candidates.count))
                carried = candidates.filter { remembered($0.text, in: summary) }
                pending = []
            } else if row.text(1) == "user", row.text(2) == "message" {
                for (sentence, kind) in instructions(in: text) {
                    pending.append(Item(text: sentence, kind: kind, ordinal: ordinal, timestamp: row.date(4)))
                }
            }
        }
        return gaps
    }
}
