import Foundation

/// The prompts you type again and again, from Claude Code's own record of what was typed
/// (`history.jsonl` in each config folder).
///
/// Near-identical prompts count as one: the same request with a word changed or a typo fixed
/// is still the same habit, and that's what's worth turning into a skill.
public enum PromptLibrary {

    public struct Prompt: Sendable, Identifiable, Equatable {
        public var id: String { key }
        /// The most recent wording.
        public let text: String
        public let key: String
        public let uses: Int
        public let lastUsed: Date?
        /// Project folders it was used in, most frequent first.
        public let projects: [String]
        /// Other wordings of the same prompt.
        public let variants: Int
    }

    struct Entry {
        let text: String
        let date: Date?
        let project: String?
    }

    static func entries(configDirs: [URL], paths: HostPaths) -> [Entry] {
        var out: [Entry] = []
        for config in configDirs {
            guard let data = try? Data(contentsOf: config.appendingPathComponent("history.jsonl")) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let record = try? JSONValue.parse(Data(line)),
                      let text = record["display"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                let date = record["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
                out.append(Entry(text: text, date: date, project: record["project"]?.stringValue))
            }
        }
        return out
    }

    /// Prompts used at least `minimumUses` times, most used first.
    public static func repeated(configDirs: [URL], minimumUses: Int = 3, paths: HostPaths = .current) -> [Prompt] {
        let all = entries(configDirs: configDirs, paths: paths).filter(isWorthKeeping)
        // Exact repeats first, by normalized text.
        var groups: [String: [Entry]] = [:]
        for entry in all { groups[normalize(entry.text), default: []].append(entry) }

        // Then fold near-identical groups together, biggest first so they absorb the rest.
        let keys = groups.keys.sorted {
            let (a, b) = (groups[$0]?.count ?? 0, groups[$1]?.count ?? 0)
            return a == b ? $0 < $1 : a > b
        }
        // Each prompt's words as numbers, rarest first. Two prompts sharing three quarters of
        // their words share one of each other's first few, and the first they share bounds how
        // many more they can, so most pairs are never compared at all.
        let sets = keys.map { Set($0.split(separator: " ").map(String.init)) }
        var frequency: [String: Int] = [:]
        for set in sets { for word in set { frequency[word, default: 0] += 1 } }
        let vocabulary = frequency.keys.sorted { (frequency[$0] ?? 0, $0) < (frequency[$1] ?? 0, $1) }
        let number = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        let words = sets.map { $0.compactMap { number[$0] }.sorted() }
        func leading(_ count: Int) -> Int { count - (3 * count + 3) / 4 + 1 }
        var filed = [[(prompt: Int, at: Int)]](repeating: [], count: vocabulary.count)
        for (prompt, list) in words.enumerated() where list.count >= 4 {
            for at in 0..<leading(list.count) { filed[list[at]].append((prompt, at)) }
        }
        func shared(_ a: [Int], _ b: [Int]) -> Int {
            var (i, j, count) = (0, 0, 0)
            while i < a.count, j < b.count {
                if a[i] == b[j] { count += 1; i += 1; j += 1 } else if a[i] < b[j] { i += 1 } else { j += 1 }
            }
            return count
        }
        var absorbed = [Bool](repeating: false, count: keys.count)
        var looked = [Int](repeating: -1, count: keys.count)
        var merged: [String: [String]] = [:]
        for (position, key) in keys.enumerated() where !absorbed[position] {
            absorbed[position] = true
            var members = [key]
            let own = words[position]
            if own.count >= 4 {
                for at in 0..<leading(own.count) {
                    for (other, theirAt) in filed[own[at]] where !absorbed[other] && looked[other] != position {
                        looked[other] = position
                        let theirs = words[other]
                        let needed = (3 * (own.count + theirs.count) + 6) / 7
                        guard 1 + min(own.count - at - 1, theirs.count - theirAt - 1) >= needed else { continue }
                        let common = shared(own, theirs)
                        if Double(common) / Double(own.count + theirs.count - common) >= 0.75 {
                            members.append(keys[other])
                            absorbed[other] = true
                        }
                    }
                }
            }
            merged[key] = members
        }

        return merged.compactMap { key, members -> Prompt? in
            let entries = members.flatMap { groups[$0] ?? [] }
            guard entries.count >= minimumUses else { return nil }
            let latest = entries.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            var projectCounts: [String: Int] = [:]
            for entry in entries { if let project = entry.project { projectCounts[project, default: 0] += 1 } }
            return Prompt(text: latest?.text ?? key, key: key, uses: entries.count, lastUsed: latest?.date,
                          projects: projectCounts.sorted { $0.value > $1.value }.map(\.key),
                          variants: members.count - 1)
        }
        .sorted { $0.uses == $1.uses ? ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) : $0.uses > $1.uses }
    }

    /// Short replies ("yes", "continue", "go on") and slash commands are conversation, not
    /// prompts worth keeping.
    static func isWorthKeeping(_ entry: Entry) -> Bool {
        let text = entry.text
        guard !text.hasPrefix("/"), !text.hasPrefix("!") else { return false }
        return text.split(whereSeparator: \.isWhitespace).count >= 4 && text.count >= 20
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Turns something you keep asking for into a Claude Code skill.
public enum SkillFactory {

    public struct Draft: Sendable, Equatable {
        public var name: String
        public var description: String
        public var body: String

        public var markdown: String {
            "---\nname: \(name)\ndescription: \(description.replacingOccurrences(of: "\n", with: " "))\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
    }

    /// A first draft from a prompt: its words as the instructions, a name from its opening.
    public static func draft(from prompt: String) -> Draft {
        let words = PromptLibrary.normalize(prompt).split(separator: " ").map(String.init)
        let filler: Set<String> = ["please", "can", "you", "could", "the", "a", "an", "and", "to", "for", "of", "this", "that", "my", "i", "we", "it", "in", "on", "with"]
        let name = words.filter { !filler.contains($0) }.prefix(4).joined(separator: "-")
        var firstSentence = prompt.split(whereSeparator: { ".\n?!".contains($0) }).first.map(String.init) ?? prompt
        for polite in ["please ", "can you ", "could you ", "would you "] where firstSentence.lowercased().hasPrefix(polite) {
            firstSentence = String(firstSentence.dropFirst(polite.count))
        }
        return Draft(name: name.isEmpty ? "my-skill" : name,
                     description: "Use when asked to \(firstSentence.prefix(160).trimmingCharacters(in: .whitespaces).lowercasedFirst)",
                     body: "When this skill applies, do the following.\n\n\(prompt)")
    }

    /// Skill names are folder names Claude Code reads: lowercase letters, digits and hyphens.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    public enum Failure: Error, CustomStringConvertible {
        case invalidName, exists(String)
        public var description: String {
            switch self {
            case .invalidName: return "A skill's name can only have lowercase letters, numbers and hyphens."
            case .exists(let name): return "There's already a skill called \(name) there."
            }
        }
    }

    /// Writes the skill into a Claude Code config folder's `skills/`, with a receipt so
    /// History can take it out again.
    @discardableResult
    public static func install(_ draft: Draft, in configDir: URL) throws -> ImportReceipt {
        guard isValidName(draft.name) else { throw Failure.invalidName }
        let folder = configDir.appendingPathComponent("skills/\(draft.name)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Failure.exists(draft.name) }
        var receipt = ImportReceipt(direction: .skill, destination: folder.path)
        receipt.title = "Skill \(draft.name)"
        receipt.itemCount = 1
        try Undo.save(receipt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        receipt.recordCreatedDirectory(at: folder)
        let file = folder.appendingPathComponent("SKILL.md")
        try AtomicWrite.write(Data(draft.markdown.utf8), to: file)
        try receipt.recordCreatedFile(at: file)
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        // Keep acronyms and names as they are.
        if count > 1, self[index(after: startIndex)].isUppercase { return self }
        return first.lowercased() + dropFirst()
    }
}
