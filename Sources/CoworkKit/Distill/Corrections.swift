import Foundation

/// What you keep telling Claude after it gets something wrong, as lines for CLAUDE.md, so the
/// next session starts knowing it.
public struct CorrectionSuggestion: Sendable, Identifiable, Equatable {
    public struct Example: Sendable, Equatable {
        public let text: String
        public let conversationID: String
        public let conversationTitle: String
        public let date: Date?
    }

    public var id: String { "\(project ?? "~")#\(key)" }
    /// The project folder, or `nil` for a correction made across projects.
    public let project: String?
    /// A first wording of the rule, from the plainest example.
    public let rule: String
    public let examples: [Example]
    let key: String

    public var conversations: Int { Set(examples.map(\.conversationID)).count }
}

public enum Corrections {

    /// Openings that push back on what Claude just did.
    static let openers = ["no", "nope", "don't", "dont", "do not", "stop", "never", "wrong", "that's wrong", "thats wrong",
                          "that's not", "thats not", "not like that", "actually", "instead", "please don't", "please do not",
                          "please never", "please always", "you should", "you shouldn't", "always", "i said", "i told you",
                          "again,", "remember", "i meant", "i asked", "that's not what", "thats not what", "we use",
                          "we don't", "we dont", "we never", "we always", "this repo uses", "this project uses"]

    /// A short reply to Claude that corrects it.
    static func isCorrection(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...280).contains(lower.count), !lower.hasPrefix("/"), !lower.contains("\n\n") else { return false }
        if openers.contains(where: { opener in
            lower.hasPrefix(opener) && (lower.count == opener.count
                || !(lower[lower.index(lower.startIndex, offsetBy: opener.count)].isLetter))
        }) { return true }
        return lower.hasPrefix("use ") && (lower.contains(" not ") || lower.contains(" instead"))
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "this", "that", "with", "not", "don", "dont", "please", "use", "should",
        "never", "always", "again", "here", "there", "it's", "its", "are", "was", "but", "just", "all", "any", "can",
        "have", "has", "from", "into", "then", "than", "them", "they", "what", "when", "which", "said", "told", "stop",
        "nope", "wrong", "actually", "instead", "remember", "like", "also", "one", "our", "out", "about",
    ]

    /// The words that carry what a correction is about.
    static func terms(_ text: String) -> Set<String> {
        Set(PromptLibrary.normalize(text).split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// "no, use pnpm here not npm" → "Use pnpm here not npm."
    public static func rule(from text: String) -> String {
        var rule = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leads = ["no,", "no.", "no —", "no -", "no:", "nope,", "nope.", "actually,", "again,", "i said", "i told you",
                     "i meant", "please", "remember", "wrong,", "wrong."]
        var changed = true
        while changed {
            changed = false
            for lead in leads where rule.lowercased().hasPrefix(lead) {
                rule = String(rule.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                changed = true
            }
            if rule.lowercased().hasPrefix("no ") && rule.count > 3 { rule = String(rule.dropFirst(3)); changed = true }
        }
        rule = rule.trimmingCharacters(in: .whitespaces)
        guard let first = rule.first else { return text }
        rule = first.uppercased() + rule.dropFirst()
        if !".!?".contains(rule.last ?? ".") { rule += "." }
        return rule
    }

    /// Corrections made in at least two conversations: per project, and across three or more
    /// projects for the CLAUDE.md every session reads.
    public static func suggestions(index: HistoryIndex, paths: HostPaths = .current,
                                   minimumConversations: Int = 2) async throws -> [CorrectionSuggestion] {
        let rows = try await index.rows("""
            SELECT m.conversation_id, m.ordinal, m.role, m.text, m.timestamp, c.title, c.project_path
            FROM messages m JOIN conversations c ON c.id = m.conversation_id
            WHERE m.kind = 'message' AND c.project_path LIKE '/%'
            ORDER BY m.conversation_id, m.ordinal
            """)
        struct Found { let terms: Set<String>; let example: CorrectionSuggestion.Example; let project: String }
        var found: [Found] = []
        var previousRole: String?
        var previousConversation: String?
        for row in rows {
            guard let id = row.text(0), let role = row.text(2), let text = row.text(3) else { continue }
            if id != previousConversation { previousRole = nil; previousConversation = id }
            defer { previousRole = role }
            guard role == "user", previousRole == "assistant", isCorrection(text),
                  let project = row.text(6).map(Projects.root(of:)) else { continue }
            let words = terms(text)
            guard !words.isEmpty else { continue }
            found.append(Found(terms: words, example: .init(text: text, conversationID: id, conversationTitle: row.text(5) ?? "Untitled",
                                                            date: row.date(4)), project: project))
        }

        // Group corrections about the same thing: most of their words in common.
        func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
            let shared = a.intersection(b).count
            guard shared >= min(2, min(a.count, b.count)) else { return false }
            return Double(shared) / Double(a.union(b).count) >= 0.4
        }
        var clusters: [[Found]] = []
        for item in found {
            if let index = clusters.firstIndex(where: { similar($0[0].terms, item.terms) }) {
                clusters[index].append(item)
            } else {
                clusters.append([item])
            }
        }

        var suggestions: [CorrectionSuggestion] = []
        for cluster in clusters {
            let key = cluster[0].terms.sorted().joined(separator: " ")
            let byProject = Dictionary(grouping: cluster, by: \.project)
            for (project, items) in byProject where Set(items.map(\.example.conversationID)).count >= minimumConversations {
                let plainest = items.min { $0.example.text.count < $1.example.text.count }!
                let suggestion = CorrectionSuggestion(project: project, rule: rule(from: plainest.example.text),
                                                      examples: items.map(\.example).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) },
                                                      key: key)
                if !alreadyKnown(suggestion, paths: paths) { suggestions.append(suggestion) }
            }
            if byProject.count >= 3 {
                let plainest = cluster.min { $0.example.text.count < $1.example.text.count }!
                let suggestion = CorrectionSuggestion(project: nil, rule: rule(from: plainest.example.text),
                                                      examples: cluster.map(\.example), key: key)
                if !alreadyKnown(suggestion, paths: paths) { suggestions.append(suggestion) }
            }
        }
        return suggestions.sorted { $0.examples.count > $1.examples.count }
    }

    /// The CLAUDE.md a suggestion belongs in.
    public static func target(for project: String?, paths: HostPaths = .current) -> URL {
        project.map { URL(fileURLWithPath: $0).appendingPathComponent("CLAUDE.md") }
            ?? paths.claudeCodeConfigDir.appendingPathComponent("CLAUDE.md")
    }

    /// Whether the CLAUDE.md already says it: most of the rule's words are there.
    static func alreadyKnown(_ suggestion: CorrectionSuggestion, paths: HostPaths) -> Bool {
        guard let existing = try? String(contentsOf: target(for: suggestion.project, paths: paths), encoding: .utf8) else { return false }
        let words = terms(suggestion.rule)
        guard !words.isEmpty else { return true }
        let present = terms(existing)
        return Double(words.intersection(present).count) / Double(words.count) >= 0.6
    }

    static let heading = "## Corrections from past sessions"

    /// Adds `rules` to a CLAUDE.md under one heading of its own, with a receipt: History's Undo
    /// puts the file back as it was, or removes it if this made it.
    @discardableResult
    public static func add(_ rules: [String], to file: URL, paths: HostPaths = .current) throws -> ImportReceipt {
        let fm = FileManager.default
        var receipt = ImportReceipt(direction: .fileRestore, destination: file.path)
        receipt.title = "Added \(rules.count) line\(rules.count == 1 ? "" : "s") to \(file.lastPathComponent)"
        receipt.itemCount = rules.count
        let existed = fm.fileExists(atPath: file.path)
        var text = existed ? (try String(contentsOf: file, encoding: .utf8)) : ""
        if existed {
            let saved = try FileProvenance.saveCurrent(file, paths: paths)
            receipt.modified.append(.init(path: file.path, backupPath: saved.path, sha256Before: try FileDigest.hex(contentsOf: file)))
        }
        try Undo.save(receipt)

        let bullets = rules.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
        var lines = text.components(separatedBy: "\n")
        if let at = lines.firstIndex(of: heading) {
            // After the heading's own list, so the section stays together.
            var end = at + 1
            while end < lines.count, lines[end].hasPrefix("- ") || (lines[end].isEmpty && end == at + 1) { end += 1 }
            lines.insert(contentsOf: bullets, at: end)
            text = lines.joined(separator: "\n")
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + heading + "\n\n" + bullets.joined(separator: "\n") + "\n"
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWrite.write(Data(text.utf8), to: file)
        if !existed { try receipt.recordCreatedFile(at: file) }
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }
}
