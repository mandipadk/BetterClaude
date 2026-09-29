import Foundation

/// The shell commands Claude runs most that your settings don't allow yet, as narrow rules
/// you could add so it stops asking.
///
/// Only ever suggests a command and its subcommand (`swift test`, `git status`), never a
/// bare interpreter or anything that deletes, publishes, or reaches another machine.
public enum PermissionTuner {

    public struct Suggestion: Sendable, Identifiable, Equatable {
        public var id: String { rule }
        /// The rule for `permissions.allow`, e.g. `Bash(swift test:*)`.
        public let rule: String
        public let command: String
        public let runs: Int
        public let conversations: Int
        public let lastRun: Date?
    }

    /// First words that are never suggested, whatever follows them.
    static let neverAlone: Set<String> = [
        "rm", "rmdir", "sudo", "su", "dd", "mkfs", "diskutil", "chmod", "chown", "kill", "killall", "pkill",
        "shutdown", "reboot", "launchctl", "defaults", "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc",
        "open", "osascript", "security", "eval", "exec", "xargs", "env", "sh", "bash", "zsh", "fish",
        "python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "npx", "bunx", "pnpx", "sqlite3",
        "mv", "cp", "ln", "tee", "truncate", "crontab", "at", "tccutil", "spctl", "csrutil", "cd", "export",
        "source", ".", "gh", "wrangler", "vercel", "fly", "heroku", "aws", "gcloud", "az", "kubectl", "docker",
        // These can write files through their own flags (sed -i, find -delete, awk's system).
        "sed", "awk", "gawk", "find", "patch", "install", "unzip", "tar", "ditto", "zip",
        // Shell grammar, not commands.
        "do", "done", "then", "fi", "else", "elif", "for", "while", "until", "if", "case", "esac",
        "function", "{", "}", "(", ")", "[", "[[", "]]", "!", "select", "time", "coproc",
    ]
    /// Subcommands that change or publish things, for otherwise ordinary tools.
    static let neverSubcommands: [String: Set<String>] = [
        "git": ["push", "reset", "clean", "checkout", "restore", "rebase", "rm", "branch", "tag", "merge",
                "stash", "commit", "cherry-pick", "revert", "filter-branch", "config", "remote", "switch"],
        "npm": ["publish", "unpublish", "install", "i", "exec", "run"],
        "pnpm": ["publish", "add", "install", "i", "dlx", "exec", "run"],
        "yarn": ["publish", "add", "install", "dlx"],
        "cargo": ["publish", "install"],
        "make": ["publish", "deploy", "release", "install", "clean"],
        "brew": ["install", "uninstall", "upgrade", "update", "cleanup"],
        "swift": ["package"],
    ]

    /// Tools whose second word names what they do (`git status`, `swift test`). For anything
    /// else the second word is an argument, so the rule is the command alone.
    static let subcommandTools: Set<String> = [
        "git", "swift", "npm", "pnpm", "yarn", "make", "cargo", "go", "brew", "pip", "pip3", "uv", "poetry",
        "bundle", "rake", "mix", "dotnet", "flutter", "xcrun", "xcodebuild", "mvn", "gradle", "deno", "bun",
        "turbo", "nx", "just", "task", "tsc", "jest", "vitest", "pytest", "rustup", "cmake", "ninja",
    ]
    /// Shell words that lead into a command rather than being one.
    static let leadIns: Set<String> = ["do", "then", "else", "!", "time", "{", "("]

    /// The command a shell line runs, as a rule prefix: its first word and, when the second
    /// is a subcommand rather than a flag or path, that too. `nil` when it's not safe to
    /// suggest.
    public static func prefixes(of line: String) -> [String] {
        let segments = line.components(separatedBy: "&&").flatMap { $0.components(separatedBy: ";") }
            .flatMap { $0.components(separatedBy: "||") }.flatMap { $0.components(separatedBy: "|") }
        return segments.compactMap { segment in
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            // Leading variable assignments and shell lead-ins don't change what runs.
            while let first = words.first, first.contains("=") || leadIns.contains(first) { words.removeFirst() }
            guard let command = words.first, !command.isEmpty else { return nil }
            let name = (command as NSString).lastPathComponent
            guard !neverAlone.contains(name), command == name || !command.contains("/") else { return nil }
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else { return nil }
            if words.count > 1, subcommandTools.contains(name) {
                let sub = words[1]
                if sub.first?.isLetter == true, sub.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    if neverSubcommands[name]?.contains(sub) == true { return nil }
                    return "\(name) \(sub)"
                }
            }
            // A tool whose subcommands vary this much is only suggested with one.
            return neverSubcommands[name] == nil ? name : nil
        }
    }

    /// `permissions.allow` from a config folder's settings and local settings.
    public static func allowRules(configDir: URL) -> [String] {
        ["settings.json", "settings.local.json"].flatMap { name -> [String] in
            guard let data = try? Data(contentsOf: configDir.appendingPathComponent(name)),
                  let value = try? JSONValue.parse(data) else { return [] }
            return value["permissions"]?["allow"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
    }

    /// Whether an existing rule already lets `prefix` run.
    static func covered(_ prefix: String, by rules: [String]) -> Bool {
        rules.contains { rule in
            if rule == "Bash" || rule == "Bash(*)" { return true }
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
            var body = String(rule.dropFirst(5).dropLast())
            for suffix in [":*", " *", "*"] where body.hasSuffix(suffix) {
                body = String(body.dropLast(suffix.count))
                return prefix == body || prefix.hasPrefix(body + " ")
            }
            return prefix == body
        }
    }

    public static func suggestions(index: HistoryIndex, configDir: URL, since: Date,
                                   minimumRuns: Int = 5, minimumConversations: Int = 2) async throws -> [Suggestion] {
        let rows = try await index.rows("""
            SELECT t.detail, t.conversation_id, t.timestamp FROM tool_calls t
            JOIN conversations c ON c.id = t.conversation_id
            WHERE t.name = 'Bash' AND t.detail IS NOT NULL AND t.timestamp >= ?
              AND c.kind IN ('claudeCode', 'codeTab')
            """, [.date(since)])
        struct Tally { var runs = 0; var conversations = Set<String>(); var last: Date? }
        var tallies: [String: Tally] = [:]
        for row in rows {
            guard let line = row.text(0), let conversation = row.text(1) else { continue }
            for prefix in Set(prefixes(of: line)) {
                var tally = tallies[prefix, default: Tally()]
                tally.runs += 1
                tally.conversations.insert(conversation)
                if let date = row.date(2), date > (tally.last ?? .distantPast) { tally.last = date }
                tallies[prefix] = tally
            }
        }
        let rules = allowRules(configDir: configDir)
        return tallies.compactMap { prefix, tally -> Suggestion? in
            guard tally.runs >= minimumRuns, tally.conversations.count >= minimumConversations,
                  !covered(prefix, by: rules) else { return nil }
            return Suggestion(rule: "Bash(\(prefix):*)", command: prefix, runs: tally.runs,
                              conversations: tally.conversations.count, lastRun: tally.last)
        }
        .sorted { $0.runs == $1.runs ? $0.command < $1.command : $0.runs > $1.runs }
    }

    // MARK: Changing settings

    static func ledgerURL(paths: HostPaths) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Permissions/added.json")
    }

    /// Rules Better Claude added, by config folder, so they can be taken out again exactly.
    public static func added(configDir: URL, paths: HostPaths = .current) -> [String] {
        guard let data = try? Data(contentsOf: ledgerURL(paths: paths)),
              let ledger = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return ledger[configDir.standardizedFileURL.path] ?? []
    }

    static func saveLedger(_ rules: [String], configDir: URL, paths: HostPaths) throws {
        var ledger = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: ledgerURL(paths: paths)))) ?? [:]
        ledger[configDir.standardizedFileURL.path] = rules.isEmpty ? nil : rules
        try FileManager.default.createDirectory(at: ledgerURL(paths: paths).deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWrite.write(try JSONEncoder().encode(ledger), to: ledgerURL(paths: paths))
    }

    /// Adds rules to the config folder's `settings.json`, backing it up first.
    public static func allow(_ rules: [String], configDir: URL, paths: HostPaths = .current) throws {
        try editAllow(configDir: configDir, paths: paths) { allow in
            for rule in rules where !allow.contains(rule) { allow.append(rule) }
        }
        try saveLedger(Array(Set(added(configDir: configDir, paths: paths) + rules)).sorted(), configDir: configDir, paths: paths)
    }

    /// Takes out rules Better Claude added, and only those.
    public static func removeAdded(_ rules: [String]? = nil, configDir: URL, paths: HostPaths = .current) throws {
        let mine = added(configDir: configDir, paths: paths)
        let removing = Set(rules ?? mine).intersection(mine)
        guard !removing.isEmpty else { return }
        try editAllow(configDir: configDir, paths: paths) { allow in allow.removeAll { removing.contains($0) } }
        try saveLedger(mine.filter { !removing.contains($0) }, configDir: configDir, paths: paths)
    }

    static func editAllow(configDir: URL, paths: HostPaths, _ change: (inout [String]) -> Void) throws {
        var settings = try PulseHooks.readSettings(in: configDir)
        try PulseHooks.backUp(configDir: configDir, paths: paths)
        var permissions = settings["permissions"]?.objectValue ?? JSONObject()
        var allow = permissions["allow"]?.arrayValue?.compactMap(\.stringValue) ?? []
        change(&allow)
        permissions["allow"] = .array(allow.map(JSONValue.string))
        settings["permissions"] = .object(permissions)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try AtomicWrite.write(settings.serializedPretty(), to: PulseHooks.settingsURL(in: configDir))
    }
}

/// What's going wrong around Claude Code's turns: MCP servers that failed to start or need
/// signing in to, and hooks that fail — recorded in the transcripts as it happens.
public enum Doctor {

    public struct Issue: Sendable, Identifiable, Equatable {
        public var id: String { "\(kind.rawValue):\(name)" }
        public let kind: TranscriptScan.HealthEvent.Kind
        public let name: String
        public let detail: String?
        public let lastSeen: Date?
        public let times: Int
    }

    public static func issues(index: HistoryIndex, installIDs: Set<String>, since: Date) async throws -> [Issue] {
        guard !installIDs.isEmpty else { return [] }
        let rows = try await index.rows("""
            SELECT h.kind, h.name, MAX(h.timestamp), COUNT(*),
                   (SELECT detail FROM health WHERE kind = h.kind AND name = h.name ORDER BY timestamp DESC LIMIT 1)
            FROM health h JOIN conversations c ON c.id = h.conversation_id
            WHERE h.timestamp >= ? AND c.install_id IN (\(installIDs.map { _ in "?" }.joined(separator: ",")))
            GROUP BY h.kind, h.name ORDER BY MAX(h.timestamp) DESC
            """, [.date(since)] + installIDs.sorted().map(SQLiteValue.text))
        return rows.compactMap { row in
            guard let kind = row.text(0).flatMap(TranscriptScan.HealthEvent.Kind.init(rawValue:)),
                  let name = row.text(1) else { return nil }
            return Issue(kind: kind, name: name, detail: row.text(4), lastSeen: row.date(2), times: Int(row.int(3)))
        }
    }
}

/// A week of work across every Claude, in numbers and in Claude's own recaps.
public struct WeekDigest: Sendable, Equatable {
    public let since: Date
    public let conversations: Int
    public let prompts: Int
    /// Where the work happened, busiest first.
    public let places: [(name: String, conversations: Int)]
    public let projects: [(name: String, conversations: Int)]
    public let filesChanged: Int
    public let commands: Int
    /// Claude's recaps from the week, latest last.
    public let recaps: [String]
    public let titles: [String]

    public static func == (a: WeekDigest, b: WeekDigest) -> Bool {
        a.since == b.since && a.conversations == b.conversations && a.prompts == b.prompts
            && a.filesChanged == b.filesChanged && a.commands == b.commands && a.recaps == b.recaps
            && a.titles == b.titles && a.places.map(\.name) == b.places.map(\.name)
            && a.projects.map(\.name) == b.projects.map(\.name)
    }

    public static func build(index: HistoryIndex, since: Date, accountIDs: Set<String>? = nil) async throws -> WeekDigest {
        var filter = "last_activity >= ?"
        var values: [SQLiteValue] = [.date(since)]
        if let accountIDs {
            filter += " AND account_id IN (\(accountIDs.map { _ in "?" }.joined(separator: ",")))"
            values += accountIDs.sorted().map(SQLiteValue.text)
        }
        let conversations = try await index.rows("SELECT id, kind, install_name, project_path, title FROM conversations WHERE \(filter) ORDER BY last_activity DESC", values)
        let ids = conversations.compactMap { $0.text(0) }
        guard !ids.isEmpty else {
            return WeekDigest(since: since, conversations: 0, prompts: 0, places: [], projects: [], filesChanged: 0,
                              commands: 0, recaps: [], titles: [])
        }
        var places: [String: Int] = [:]
        var projects: [String: Int] = [:]
        for row in conversations {
            places[HistorySearch.place(kind: row.text(1), install: row.text(2)), default: 0] += 1
            if let project = row.text(3) { projects[URL(fileURLWithPath: project).lastPathComponent, default: 0] += 1 }
        }
        let list = ids.map { _ in "?" }.joined(separator: ",")
        let idValues = ids.map(SQLiteValue.text)
        let prompts = try await index.rows("SELECT COUNT(*) FROM messages WHERE role = 'user' AND kind = 'message' AND timestamp >= ? AND conversation_id IN (\(list))", [.date(since)] + idValues).first?.int(0) ?? 0
        let files = try await index.rows("SELECT COUNT(DISTINCT file_path) FROM tool_calls WHERE file_path IS NOT NULL AND name IN ('Edit','Write','MultiEdit','NotebookEdit') AND timestamp >= ? AND conversation_id IN (\(list))", [.date(since)] + idValues).first?.int(0) ?? 0
        let commands = try await index.rows("SELECT COUNT(*) FROM tool_calls WHERE name = 'Bash' AND timestamp >= ? AND conversation_id IN (\(list))", [.date(since)] + idValues).first?.int(0) ?? 0
        let recaps = try await index.rows("SELECT text FROM messages WHERE kind = 'recap' AND timestamp >= ? AND conversation_id IN (\(list)) ORDER BY timestamp DESC LIMIT 16", [.date(since)] + idValues).compactMap { $0.text(0) }
        return WeekDigest(
            since: since, conversations: ids.count, prompts: Int(prompts),
            places: places.sorted { $0.value > $1.value }.map { ($0.key.prefix(1).uppercased() + $0.key.dropFirst(), $0.value) },
            projects: projects.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) },
            filesChanged: Int(files), commands: Int(commands), recaps: recaps.reversed(),
            titles: conversations.prefix(20).compactMap { $0.text(4) })
    }

    public static let instructions = """
    You write a short weekly summary of someone's work with Claude, from notes. Three to five \\
    bullet points on what they worked on and what got done, by project where you can tell, \\
    then one line on what looks unfinished. Use only the notes. No preamble, no headings.
    """

    public var prompt: String {
        var notes = "Conversations this week, most recent first:\n" + titles.map { "- \($0)" }.joined(separator: "\n")
        if !recaps.isEmpty { notes += "\n\nClaude's recaps:\n" + recaps.map { "- \($0)" }.joined(separator: "\n") }
        return String(notes.prefix(9_000))
    }
}
