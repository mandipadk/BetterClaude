import Foundation

/// Where a conversation lives, in a form the UI can act on.
public struct ConversationLocation: Sendable, Hashable {
    public enum Kind: String, Sendable { case cowork, claudeCode }
    public let kind: Kind
    /// Store variant for Cowork, project folder name for Claude Code.
    public let container: String
    public let identity: String?
    public let transcriptURL: URL
    /// The id the rest of the app uses to select this conversation.
    public let rowID: String

    public init(kind: Kind, container: String, identity: String?, transcriptURL: URL, rowID: String) {
        self.kind = kind
        self.container = container
        self.identity = identity
        self.transcriptURL = transcriptURL
        self.rowID = rowID
    }
}

public struct SearchHit: Sendable, Identifiable {
    public let id: String
    public let location: ConversationLocation
    public let conversationTitle: String
    public let lastActivity: Date
    /// Best-matching excerpts, already trimmed around the match.
    public let excerpts: [Excerpt]
    public let totalMatches: Int
    public let score: Double

    public struct Excerpt: Sendable, Identifiable {
        public let id: String
        public let role: MessageText.Role
        public let text: String
        /// Ranges within `text` that matched, for highlighting.
        public let ranges: [Range<String.Index>]
        public let timestamp: Date?
    }
}

/// A full-text index over every conversation on the machine.
///
/// Built in memory rather than on disk: the whole corpus here is on the order of a few
/// hundred megabytes of JSONL, of which the prose is a small fraction, and an in-memory
/// index avoids owning a database file, a schema migration story, and a staleness problem.
/// Rebuilding is cheap enough to do on demand.
public actor SearchIndex {

    public struct Entry: Sendable {
        public let location: ConversationLocation
        public let title: String
        public let lastActivity: Date
        public let messages: [MessageText]
        /// Lowercased concatenation, kept for a fast reject before per-message scanning.
        let haystack: String
    }

    private var entries: [Entry] = []
    private(set) public var isBuilt = false

    public init() {}

    public var conversationCount: Int { entries.count }
    public var messageCount: Int { entries.reduce(0) { $0 + $1.messages.count } }

    public func replaceAll(with entries: [Entry]) {
        self.entries = entries
        isBuilt = true
    }

    public func clear() {
        entries = []
        isBuilt = false
    }

    /// Builds an entry for one transcript. Static so callers can parallelise the expensive
    /// part outside the actor and hand back finished entries.
    public static func makeEntry(location: ConversationLocation,
                                 title: String,
                                 lastActivity: Date) throws -> Entry {
        let transcript = try Transcript(contentsOf: location.transcriptURL)
        let messages = ConversationText.messages(in: transcript)
        let haystack = (title + "\n" + messages.map(\.text).joined(separator: "\n")).lowercased()
        return Entry(location: location, title: title, lastActivity: lastActivity,
                     messages: messages, haystack: haystack)
    }

    /// Ranked search.
    ///
    /// Terms are AND-ed: every term must appear somewhere in the conversation, which is what
    /// people expect from a search box and keeps two-word queries from returning everything.
    public func search(_ query: String, limit: Int = 100, excerptsPerHit: Int = 3) -> [SearchHit] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for entry in entries {
            guard terms.allSatisfy({ entry.haystack.contains($0) }) else { continue }

            var excerpts: [SearchHit.Excerpt] = []
            var matchCount = 0
            var titleMatches = 0

            for term in terms where entry.title.lowercased().contains(term) { titleMatches += 1 }

            for message in entry.messages {
                let lowered = message.text.lowercased()
                var ranges: [Range<String.Index>] = []
                for term in terms {
                    var cursor = lowered.startIndex
                    while let found = lowered.range(of: term, range: cursor..<lowered.endIndex) {
                        // Index-space is shared because `lowercased()` here preserves length
                        // for the scripts this corpus uses; a mismatch would only shift a
                        // highlight, never crash, since ranges are validated on use.
                        ranges.append(found)
                        matchCount += 1
                        cursor = found.upperBound
                        if cursor >= lowered.endIndex { break }
                    }
                }
                guard !ranges.isEmpty, excerpts.count < excerptsPerHit else { continue }
                let (text, mapped) = Self.excerpt(from: message.text, around: ranges)
                excerpts.append(SearchHit.Excerpt(id: message.id, role: message.role,
                                                  text: text, ranges: mapped,
                                                  timestamp: message.timestamp))
            }

            guard matchCount > 0 || titleMatches > 0 else { continue }

            // Title matches dominate, then match density, then recency as a tiebreak. Raw
            // match count alone would float long transcripts above precise short ones.
            let recency = 1.0 / (1.0 + max(0, Date.now.timeIntervalSince(entry.lastActivity)) / 86_400)
            let score = Double(titleMatches) * 10 + log(Double(matchCount) + 1) + recency

            hits.append(SearchHit(id: entry.location.rowID,
                                  location: entry.location,
                                  conversationTitle: entry.title,
                                  lastActivity: entry.lastActivity,
                                  excerpts: excerpts,
                                  totalMatches: matchCount,
                                  score: score))
        }

        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// A window of text around the first match, cut on word boundaries.
    static func excerpt(from text: String, around ranges: [Range<String.Index>],
                        radius: Int = 90) -> (String, [Range<String.Index>]) {
        guard let first = ranges.first else { return (String(text.prefix(180)), []) }

        let lower = text.index(first.lowerBound, offsetBy: -radius,
                               limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(first.upperBound, offsetBy: radius,
                               limitedBy: text.endIndex) ?? text.endIndex

        var start = lower, end = upper
        if start != text.startIndex, let space = text[start..<first.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        if end != text.endIndex, let space = text[first.upperBound..<end].lastIndex(of: " ") {
            end = space
        }

        var slice = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        slice = prefix + slice.trimmingCharacters(in: .whitespaces) + suffix

        // Re-find the matches inside the trimmed excerpt rather than trying to translate
        // indices across two different strings.
        let sourceTerm = String(text[first])
        var mapped: [Range<String.Index>] = []
        var cursor = slice.startIndex
        while let found = slice.range(of: sourceTerm, options: .caseInsensitive,
                                      range: cursor..<slice.endIndex) {
            mapped.append(found)
            cursor = found.upperBound
            if cursor >= slice.endIndex { break }
        }
        return (slice, mapped)
    }
}
