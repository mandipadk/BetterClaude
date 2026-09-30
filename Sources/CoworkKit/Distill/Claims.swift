import Foundation

/// What an agent said it did, checked against what its transcript shows it did. Only claims
/// a transcript can settle are checked — tests passing, a file changed, a commit, a build —
/// and anything else is left alone rather than guessed at.
public enum Claims {

    public struct Claim: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case testsPass, edited, committed, pushed, builds }
        public enum Verdict: Sendable, Equatable {
            /// The transcript shows it: the evidence, in words.
            case backed(String)
            /// The transcript shows the opposite: the last matching run failed.
            case contradicted(String)
            /// Nothing in the transcript does what it says.
            case noEvidence
            /// A script or command that might have done it ran, and can't be seen into.
            case unclear
        }
        public var id: String { "\(agentID ?? "main")#\(timestamp?.timeIntervalSince1970 ?? 0)#\(sentence)" }
        public let sentence: String
        public let kind: Kind
        public let verdict: Verdict
        /// The sub-agent that said it; nil for the conversation itself.
        public let agentID: String?
        public let timestamp: Date?
    }

    struct Call {
        let name: String
        let file: String?
        let detail: String?
        let failed: Bool
        let at: Date?
    }

    static let testRun = try! NSRegularExpression(pattern: #"\b(test|tests|pytest|jest|vitest|rspec|phpunit|xctest)\b"#, options: .caseInsensitive)
    static let buildRun = try! NSRegularExpression(pattern: #"\b(build|compile|tsc|xcodebuild|cargo check)\b"#, options: .caseInsensitive)
    static let testClaim = try! NSRegularExpression(pattern: #"\b(all (the )?tests? (now )?pass|tests? (now )?pass(es|ed|ing)?|tests? (are|is) (all )?(passing|green)|\d+ tests? pass(ed)?|all pass(ed)?|suite (passes|is green))\b"#, options: .caseInsensitive)
    static let editClaim = try! NSRegularExpression(pattern: #"\b(updated|edited|changed|modified|fixed|created|added|wrote|rewrote|refactored)\b[^.\n]*?([\w./-]+\.[a-z]{1,6})\b"#, options: .caseInsensitive)
    static let commitClaim = try! NSRegularExpression(pattern: #"\b(committed|made a commit|created a commit)\b"#, options: .caseInsensitive)
    static let pushClaim = try! NSRegularExpression(pattern: #"\b(pushed)\b"#, options: .caseInsensitive)
    static let buildClaim = try! NSRegularExpression(pattern: #"\b(build (succeeds|succeeded|passes|passed|is green)|builds (cleanly|fine|successfully)|compiles (cleanly|fine|without errors))\b"#, options: .caseInsensitive)

    static func matches(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The checkable claims in a reply, one per sentence.
    static func claims(in text: String) -> [(String, Claim.Kind, String?)] {
        var found: [(String, Claim.Kind, String?)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            let clean = (sentence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (8...400).contains(clean.count), !clean.hasSuffix("?") else { return }
            // Plans and conditionals aren't claims: "once the tests pass", "I'll update x.ts".
            let lower = clean.lowercased()
            if ["i'll ", "i will ", "once ", "if ", "should ", "need to", "next,", "let me ", "going to", "would "].contains(where: { lower.contains($0) }) { return }
            if matches(testClaim, clean) != nil { found.append((clean, .testsPass, nil)) }
            if matches(buildClaim, clean) != nil { found.append((clean, .builds, nil)) }
            if matches(commitClaim, clean) != nil { found.append((clean, .committed, nil)) }
            if matches(pushClaim, clean) != nil { found.append((clean, .pushed, nil)) }
            if let edit = matches(editClaim, clean), let range = Range(edit.range(at: 2), in: clean) {
                let file = String(clean[range])
                // A version number or a domain isn't a file.
                if !file.allSatisfy({ $0.isNumber || $0 == "." }), !file.hasPrefix("www."), file.contains(where: \.isLetter) {
                    found.append((clean, .edited, URL(fileURLWithPath: file).lastPathComponent))
                }
            }
        }
        return found
    }

    /// Commands that only look: they can't have run tests, edited a file or committed.
    static let lookingOnly = ["ls", "cat", "head", "tail", "grep", "rg", "find", "echo", "pwd", "wc", "which", "tree",
                              "git status", "git diff", "git log", "git show", "git branch", "sed -n", "stat", "file", "du", "open"]

    /// A command that could have done anything: a script, make, an interpreter.
    static func isOpaque(_ call: Call) -> Bool {
        let name = call.name.lowercased()
        guard name == "bash" || name.hasSuffix("__bash") || name.contains("shell") else { return false }
        // A shell whose command wasn't recorded could have done anything.
        guard let command = call.detail?.trimmingCharacters(in: .whitespaces) else { return true }
        return !lookingOnly.contains { command == $0 || command.hasPrefix($0 + " ") }
    }

    static func judge(_ kind: Claim.Kind, file: String?, calls: [Call]) -> Claim.Verdict {
        let verdict = strictJudge(kind, file: file, calls: calls)
        // Nothing visible did it, but something ran that could have: say so, not "no evidence".
        if verdict == .noEvidence, calls.contains(where: isOpaque) { return .unclear }
        return verdict
    }

    static func strictJudge(_ kind: Claim.Kind, file: String?, calls: [Call]) -> Claim.Verdict {
        let shell = calls.filter { $0.name == "Bash" }
        switch kind {
        case .testsPass, .builds:
            let expression = kind == .testsPass ? testRun : buildRun
            let runs = shell.filter { $0.detail.map { matches(expression, $0) != nil } ?? false }
            guard let last = runs.last else { return .noEvidence }
            let command = String((last.detail ?? "").prefix(80))
            return last.failed ? .contradicted("the last run, \(command), failed") : .backed("ran \(command)")
        case .edited:
            guard let file else { return .noEvidence }
            let edits = calls.filter { ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains($0.name)
                && ($0.file.map { URL(fileURLWithPath: $0).lastPathComponent == file } ?? false) }
            if edits.contains(where: { !$0.failed }) { return .backed("\(edits.filter { !$0.failed }.count) edit\(edits.count == 1 ? "" : "s") to \(file)") }
            if !edits.isEmpty { return .contradicted("every edit to \(file) failed") }
            // A shell command that names the file may have changed it (sed, a script); don't call that unbacked.
            if shell.contains(where: { $0.detail?.contains(file) ?? false }) { return .backed("a command that touched \(file)") }
            return .noEvidence
        case .committed, .pushed:
            let verb = kind == .committed ? "git commit" : "git push"
            let runs = shell.filter { $0.detail?.contains(verb) ?? false }
            guard let last = runs.last else { return .noEvidence }
            return last.failed ? .contradicted("the last \(verb) failed") : .backed("ran \(verb)")
        }
    }

    /// Every checkable claim in a conversation and its sub-agents, oldest first.
    public static func check(conversationID: String, index: HistoryIndex) async throws -> [Claim] {
        // Only where the tools are Claude Code's own; Codex's and claude.ai's can't be read this way.
        let kind = try await index.rows("SELECT kind FROM conversations WHERE id = ?", [.text(conversationID)]).first?.text(0)
        guard kind != "codex", kind != "claudeWeb" else { return [] }
        let calls = try await index.rows("""
            SELECT agent_id, name, file_path, detail, failed, timestamp FROM tool_calls WHERE conversation_id = ? ORDER BY timestamp
            """, [.text(conversationID)])
        var byAgent: [String: [Call]] = [:]
        for row in calls {
            guard let name = row.text(1) else { continue }
            byAgent[row.text(0) ?? "", default: []].append(Call(name: name, file: row.text(2), detail: row.text(3),
                                                                failed: row.int(4) != 0, at: row.date(5)))
        }
        var checked: [Claim] = []
        // Sub-agents: their final reply against everything they did.
        for row in try await index.rows("SELECT agent_id, result, last_activity FROM subagents WHERE conversation_id = ?",
                                        [.text(conversationID)]) {
            guard let agent = row.text(0), let result = row.text(1) else { continue }
            for (sentence, kind, file) in Self.claims(in: result) {
                checked.append(Claim(sentence: sentence, kind: kind, verdict: judge(kind, file: file, calls: byAgent[agent] ?? []),
                                    agentID: agent, timestamp: row.date(2)))
            }
        }
        // The conversation: each reply against everything done before it, since a summary
        // often reports work from earlier turns.
        let messages = try await index.rows("""
            SELECT role, text, timestamp FROM messages WHERE conversation_id = ? AND kind = 'message' ORDER BY ordinal
            """, [.text(conversationID)])
        let own = byAgent[""] ?? []
        for row in messages {
            guard row.text(0) == "assistant", let text = row.text(1) else { continue }
            let found = Self.claims(in: text)
            guard !found.isEmpty else { continue }
            let end = row.date(2) ?? .distantFuture
            let turn = own.filter { call in call.at.map { $0 <= end } ?? false }
            for (sentence, kind, file) in found {
                checked.append(Claim(sentence: sentence, kind: kind, verdict: judge(kind, file: file, calls: turn),
                                    agentID: nil, timestamp: row.date(2)))
            }
        }
        return checked.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }
}
