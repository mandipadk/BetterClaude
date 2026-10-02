import CryptoKit
import Foundation

/// What was decided in past conversations, with where: so neither you nor Claude decides the
/// same thing twice without knowing.
public struct Decision: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable {
        /// You said it: "let's go with…".
        case you
        /// Claude's summary of the conversation when it compacted.
        case summary
        /// Claude stated it as agreed.
        case claude
    }

    public let id: String
    public let text: String
    public let source: Source
    public let conversationID: String
    public let sessionID: String?
    public let conversationTitle: String
    public let project: String?
    public let date: Date?
}

public enum Decisions {

    static let yours = try! NSRegularExpression(pattern: #"\b(let'?s go with|let'?s use|go with|we'?ll use|we'?ll go with|i'?ve decided|i decided|decided to|decision is|let'?s keep|let'?s stick with|keep it as|stick with)\b"#, options: .caseInsensitive)
    static let claudes = try! NSRegularExpression(pattern: #"^(we decided|we'?ll go with|decision:|decided:|we agreed|agreed:|the decision)|\b(we decided|we agreed)\b"#, options: .caseInsensitive)
    static let summaries = try! NSRegularExpression(pattern: #"\b(decided|decision|chose|chosen|agreed|settled on|went with|opted for|instead of)\b"#, options: .caseInsensitive)

    /// Sentences of `text` that read as a decision, for who said it.
    static func sentences(in text: String, role: String, kind: String) -> [(String, Decision.Source)] {
        let expression: NSRegularExpression
        let source: Decision.Source
        switch (role, kind) {
        case (_, "compaction"): (expression, source) = (summaries, .summary)
        case ("user", "message"): (expression, source) = (yours, .you)
        case ("assistant", "message"): (expression, source) = (claudes, .claude)
        default: return []
        }
        var found: [(String, Decision.Source)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            for line in (sentence ?? "").components(separatedBy: "\n") {
                let clean = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*•#>")))
                guard (15...280).contains(clean.count), !clean.hasSuffix("?"), !clean.hasPrefix("```") else { continue }
                if expression.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) != nil {
                    found.append((clean, source))
                }
            }
        }
        return found
    }

    public static func list(index: HistoryIndex, project: String? = nil, topic: String? = nil,
                            accounts: Set<String>? = nil, paths: HostPaths = .current) async throws -> [Decision] {
        var filters = ["(m.kind = 'compaction' OR m.kind = 'message')"]
        var values: [SQLiteValue] = []
        if let project {
            filters.append("(c.project_path = ? OR c.project_path LIKE ? ESCAPE '\\')")
            values += [.text(project), .like("", project, "/%")]
        }
        if let accounts {
            filters.append("c.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
            values += accounts.sorted().map(SQLiteValue.text)
        }
        let rows = try await index.rows("""
            SELECT m.conversation_id, m.role, m.kind, m.text, m.timestamp, c.title, c.project_path, c.session_id
            FROM messages m JOIN conversations c ON c.id = m.conversation_id
            WHERE \(filters.joined(separator: " AND "))
            """, values)
        let dismissed = DismissedDecisions.load(paths: paths)
        let needle = topic.map { Set(PromptLibrary.normalize($0).split(separator: " ").map(String.init).filter { $0.count >= 3 }) }
        var seen = Set<String>()
        var decisions: [Decision] = []
        for row in rows {
            guard let id = row.text(0), let role = row.text(1), let kind = row.text(2), let text = row.text(3) else { continue }
            for (sentence, source) in sentences(in: text, role: role, kind: kind) {
                let normalized = PromptLibrary.normalize(sentence)
                guard seen.insert(normalized).inserted else { continue }
                if let needle, !needle.isEmpty {
                    let words = Set(normalized.split(separator: " ").map(String.init))
                    guard !needle.isDisjoint(with: words) else { continue }
                }
                let key = SHA256.hash(data: Data((id + "#" + normalized).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                guard !dismissed.contains(key) else { continue }
                decisions.append(Decision(id: key, text: sentence, source: source, conversationID: id, sessionID: row.text(7),
                                          conversationTitle: row.text(5) ?? "Untitled",
                                          project: row.text(6).map(Projects.root(of:)), date: row.date(4)))
            }
        }
        return decisions.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

/// Sentences someone said aren't decisions, by id.
public enum DismissedDecisions {
    static func url(paths: HostPaths) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Decisions/dismissed.json")
    }

    public static func load(paths: HostPaths = .current) -> Set<String> {
        guard let data = try? Data(contentsOf: url(paths: paths)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public static func dismiss(_ id: String, paths: HostPaths = .current) throws {
        var all = load(paths: paths)
        all.insert(id)
        let target = url(paths: paths)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWrite.write(try JSONEncoder().encode(all.sorted()), to: target)
    }
}
