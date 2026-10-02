import Foundation

/// When a conversation's replies came from a different model than before, and whether anyone
/// asked for it. Claude Code records the model on every reply, and a /model command or a
/// refusal fallback on the way; a change with neither is one nobody chose.
public enum ModelDrift {

    public struct Switch: Sendable, Equatable, Identifiable {
        public enum Cause: String, Sendable {
            /// You switched, with /model.
            case requested
            /// Claude Code fell back after a refusal, and said so.
            case fallback
            /// Nothing on record asked for it.
            case unexplained
        }
        public var id: String { "\(conversationID)#\(at.timeIntervalSince1970)" }
        public let conversationID: String
        public let from: String
        public let to: String
        public let at: Date
        public let cause: Cause
        /// Replies from `to` until the next switch or the end.
        public let replies: Int
    }

    /// A conversation's switches, in order.
    public static func switches(conversationID: String, index: HistoryIndex) async throws -> [Switch] {
        let replies = try await index.rows("""
            SELECT model, timestamp FROM usage
            WHERE conversation_id = ? AND agent_id IS NULL AND timestamp IS NOT NULL AND model != '<synthetic>'
            ORDER BY timestamp
            """, [.text(conversationID)]).compactMap { row -> (String, Date)? in
            guard let model = row.text(0), let at = row.date(1) else { return nil }
            return (model, at)
        }
        let markers = try await index.rows("SELECT kind, timestamp FROM model_markers WHERE conversation_id = ?",
                                           [.text(conversationID)]).compactMap { row -> (String, Date)? in
            guard let kind = row.text(0), let at = row.date(1) else { return nil }
            return (kind, at)
        }
        var found: [(from: String, to: String, at: Date, cause: Switch.Cause, index: Int)] = []
        for i in replies.indices.dropFirst() where replies[i].0 != replies[i - 1].0 {
            // What happened between the last reply on the old model and the first on the new.
            let between = markers.filter { $0.1 > replies[i - 1].1 && $0.1 <= replies[i].1 }.map(\.0)
            let cause: Switch.Cause = between.contains("requested") ? .requested
                : between.contains("fallback") ? .fallback : .unexplained
            found.append((replies[i - 1].0, replies[i].0, replies[i].1, cause, i))
        }
        return found.enumerated().map { offset, item in
            let end = offset + 1 < found.count ? found[offset + 1].index : replies.count
            return Switch(conversationID: conversationID, from: item.from, to: item.to, at: item.at,
                          cause: item.cause, replies: end - item.index)
        }
    }

    /// Unexplained switches between `since` and `until`, newest first, with the conversation's
    /// title; in these accounts' conversations, when given. A switch copied into a resumed
    /// conversation is listed once.
    public static func unexplained(index: HistoryIndex, accountIDs: Set<String>? = nil, since: Date,
                                   until: Date = .distantFuture) async throws -> [(title: String, change: Switch)] {
        if accountIDs?.isEmpty == true { return [] }
        let accounts = DistinctUsage.accounts(accountIDs)
        let candidates = try await index.rows("""
            SELECT u.conversation_id, c.title FROM usage u JOIN conversations c ON c.id = u.conversation_id
            WHERE u.agent_id IS NULL AND u.timestamp >= ? AND u.timestamp < ? AND u.model != '<synthetic>'\(accounts.sql)
            GROUP BY u.conversation_id HAVING COUNT(DISTINCT u.model) > 1
            ORDER BY MIN(c.first_activity)
            """, [.date(since), .date(until)] + accounts.values)
        var all: [(String, Switch)] = []
        var seen = Set<String>()
        for row in candidates {
            guard let id = row.text(0) else { continue }
            for change in try await switches(conversationID: id, index: index)
            where change.cause == .unexplained && change.at >= since && change.at < until {
                guard seen.insert("\(change.at.timeIntervalSince1970)|\(change.from)|\(change.to)").inserted else { continue }
                all.append((row.text(1) ?? "Untitled", change))
            }
        }
        return all.sorted { $0.1.at > $1.1.at }
    }
}
