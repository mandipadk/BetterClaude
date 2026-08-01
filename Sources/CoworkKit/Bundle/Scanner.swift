import Foundation

/// The result of sweeping a tree for credentials.
///
/// The report records *where* and *which rule*, never *what*. A scanner that quotes the
/// matched text into its report has made a second copy of the secret, in a file the user is
/// about to hand to someone else.
public struct ScanReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case clean, warn, block }

    public var status: Status
    public var findings: [Finding]
    /// Relative paths that could not be read, or that were not regular files. Non-empty
    /// always means ``Status/block``: a file we could not look inside is not a file we can
    /// promise is clean.
    public var unreadable: [String]
    public var filesScanned: Int
    public var bytesScanned: Int

    public struct Finding: Codable, Sendable {
        public var path: String
        public var ruleId: String
        public var count: Int
        /// `"block"` or `"warn"`.
        public var tier: String

        public init(path: String, ruleId: String, count: Int, tier: String) {
            self.path = path
            self.ruleId = ruleId
            self.count = count
            self.tier = tier
        }
    }

    public init(status: Status, findings: [Finding], unreadable: [String],
                filesScanned: Int, bytesScanned: Int) {
        self.status = status
        self.findings = findings
        self.unreadable = unreadable
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
    }

    public var blockFindings: [Finding] {
        findings.filter { $0.tier == Scanner.Rule.Tier.block.rawValue }
    }

    public var warnFindings: [Finding] {
        findings.filter { $0.tier == Scanner.Rule.Tier.warn.rawValue }
    }
}

/// A credential sweep over an arbitrary directory tree.
///
/// Three of its behaviours are non-obvious and each is a correction of a real failure mode:
/// it traverses dotfiles (the default ignore rules of every grep-like tool skip `.claude/`,
/// where credentials actually live); it never skips a file for being large (the 17–21 MB
/// transcripts are precisely where a pasted key hides, and binary content is detected by
/// sniffing a NUL byte, not by length); and an unreadable entry blocks rather than being
/// passed over.
public enum Scanner {

    public struct Rule: Sendable, Hashable {
        public enum Tier: String, Sendable, Codable, Hashable { case block, warn }

        public let id: String
        public let tier: Tier
        /// ICU pattern, evaluated with `NSRegularExpression`.
        public let pattern: String
        /// Case-insensitive literal substrings, at least one of which must appear in the
        /// file before the pattern is run. Purely an optimisation — every hint is a
        /// mandatory literal of the pattern, so skipping cannot lose a match.
        public let hints: [String]
        /// 1-based capture group holding the candidate value. Warn-tier rules use it for
        /// false-positive gating; block-tier rules leave it `nil`.
        public let valueGroup: Int?

        public init(id: String, tier: Tier, pattern: String, hints: [String], valueGroup: Int? = nil) {
            self.id = id
            self.tier = tier
            self.pattern = pattern
            self.hints = hints
            self.valueGroup = valueGroup
        }
    }

    // MARK: Rules

    /// High-confidence credential shapes. A single hit stops the export.
    public static var blockRules: [Rule] {
        [
            Rule(id: "anthropic-api-key", tier: .block,
                 pattern: #"sk-ant-[A-Za-z0-9_-]{20,}"#, hints: ["sk-ant-"]),
            Rule(id: "openai-api-key", tier: .block,
                 pattern: #"\bsk-(proj-)?[A-Za-z0-9]{32,}"#, hints: ["sk-"]),
            Rule(id: "github-token", tier: .block,
                 pattern: #"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#,
                 hints: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
            Rule(id: "aws-access-key-id", tier: .block,
                 pattern: #"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#, hints: ["AKIA", "ASIA"]),
            Rule(id: "private-key-block", tier: .block,
                 pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, hints: ["PRIVATE KEY"]),
            Rule(id: "slack-token", tier: .block,
                 pattern: #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, hints: ["xox"]),
            Rule(id: "stripe-key", tier: .block,
                 pattern: #"\b[rs]k_(live|test)_[A-Za-z0-9]{20,}"#,
                 hints: ["k_live_", "k_test_"]),
            Rule(id: "npm-token", tier: .block,
                 pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#, hints: ["npm_"]),
            Rule(id: "google-api-key", tier: .block,
                 pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#, hints: ["AIza"]),
            Rule(id: "jwt", tier: .block,
                 pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
                 hints: ["eyJ"]),
            Rule(id: "bearer-token", tier: .block,
                 pattern: #"[Bb]earer\s+[A-Za-z0-9._-]{20,}"#, hints: ["earer"]),
            Rule(id: "url-userinfo", tier: .block,
                 pattern: #"https?://[^/\s:@]+:[^@/\s"']{4,}@"#, hints: ["://"]),
            Rule(id: "oauth-json", tier: .block,
                 pattern: #""(accessToken|refreshToken|client_secret)"\s*:\s*"[^"]{8,}""#,
                 hints: ["accessToken", "refreshToken", "client_secret"]),
        ]
    }

    /// Shapes that are usually documentation and occasionally a real key. Every hit is put
    /// through ``isPlaceholder(_:)`` before it is reported.
    public static var warnRules: [Rule] {
        [
            Rule(id: "api-key-assignment", tier: .warn,
                 pattern: #"(?i)api[_-]?key["']?\s*[:=]\s*["']?([A-Za-z0-9_./+\-]{6,})"#,
                 hints: ["apikey", "api_key", "api-key"], valueGroup: 1),
            Rule(id: "secret-assignment", tier: .warn,
                 pattern: #"(?i)(secret_key|auth_token|access_token)["']?\s*[:=]\s*["']?([A-Za-z0-9_./+\-]{6,})"#,
                 hints: ["secret_key", "auth_token", "access_token"], valueGroup: 2),
            Rule(id: "password-assignment", tier: .warn,
                 pattern: #"(?i)passw(or)?d["']?\s*[:=]\s*["']?([^\s"',;]{6,})"#,
                 hints: ["password", "passwd"], valueGroup: 2),
        ]
    }

    // MARK: False-positive gate

    /// Vocabulary that marks a captured value as documentation rather than a credential.
    private static let placeholderNeedles = [
        "your", "example", "placeholder", "redact", "dummy", "test", "sample",
        "changeme", "change_me", "process.env", "os.environ", "getenv", "getpass",
        "input(", "prompt(", "<", ">", "${", "$(", "{{", "xxx", "...", "****",
        "todo", "fixme", "insert", "replace", "hunter2", "abc123", "123456",
        "notreal", "fake", "mykey", "somekey", "keyhere", "n/a",
    ]

    /// A captured value is treated as a placeholder — and the finding dropped — when it
    /// contains no digit at all, when it names a familiar stand-in, or when it is a shell
    /// or template variable reference.
    ///
    /// The no-digit test is what does most of the work: real keys are drawn from an
    /// alphanumeric alphabet and essentially always carry digits, while `os.getenv`,
    /// `YOUR_KEY_HERE` and `settings.API_KEY` never do. A purely alphabetic value is an
    /// English word, not entropy.
    public static func isPlaceholder(_ value: String) -> Bool {
        if value.hasPrefix("$") { return true }
        let lowered = value.lowercased()
        if placeholderNeedles.contains(where: { lowered.contains($0) }) { return true }
        if !value.unicodeScalars.contains(where: { $0.value >= 48 && $0.value <= 57 }) { return true }
        return false
    }

    // MARK: Scanning

    public static func scan(root: URL) throws -> ScanReport {
        let compiled = try (blockRules + warnRules).map { try CompiledRule($0) }
        let walk = try BundleFS.walk(root)

        // A symlink, a fifo or a directory we could not list is not a file we have looked
        // inside, and silently passing over one is exactly how a credential escapes.
        var unreadable = walk.symlinks + walk.irregular + walk.unreadable
        var findings: [ScanReport.Finding] = []
        var filesScanned = 0
        var bytesScanned = 0

        for rel in walk.files {
            let url = root.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                unreadable.append(rel)
                continue
            }
            filesScanned += 1
            if isBinary(data) { continue }
            bytesScanned += data.count

            let text = String(decoding: data, as: UTF8.self) as NSString
            let full = NSRange(location: 0, length: text.length)
            for rule in compiled {
                guard rule.mayMatch(text) else { continue }
                let count = rule.countMatches(in: text, range: full)
                if count > 0 {
                    findings.append(ScanReport.Finding(path: rel, ruleId: rule.rule.id,
                                                       count: count, tier: rule.rule.tier.rawValue))
                }
            }
        }

        findings.sort { ($0.path, $0.ruleId) < ($1.path, $1.ruleId) }
        unreadable = Array(Set(unreadable)).sorted()

        let status: ScanReport.Status
        if !unreadable.isEmpty || findings.contains(where: { $0.tier == Rule.Tier.block.rawValue }) {
            status = .block
        } else if findings.isEmpty {
            status = .clean
        } else {
            status = .warn
        }

        return ScanReport(status: status, findings: findings, unreadable: unreadable,
                          filesScanned: filesScanned, bytesScanned: bytesScanned)
    }

    /// Binary detection by NUL sniffing in the first 8 KiB. Size is never a reason to skip:
    /// the biggest transcripts are the likeliest place for a pasted key.
    static func isBinary(_ data: Data) -> Bool {
        let limit = min(data.count, 8 * 1024)
        guard limit > 0 else { return false }
        return data.prefix(limit).contains(0)
    }
}

/// A rule with its pattern compiled. Kept file-private to the scanner so a compiled regex
/// never has to be stored in a `Sendable` public type.
private struct CompiledRule {
    let rule: Scanner.Rule
    let regex: NSRegularExpression

    init(_ rule: Scanner.Rule) throws {
        self.rule = rule
        self.regex = try NSRegularExpression(pattern: rule.pattern, options: [])
    }

    /// Cheap literal pre-filter. Every hint is a mandatory literal of the pattern, so a
    /// file containing none of them cannot match.
    func mayMatch(_ text: NSString) -> Bool {
        guard !rule.hints.isEmpty else { return true }
        for hint in rule.hints
        where text.range(of: hint, options: [.caseInsensitive, .literal]).location != NSNotFound {
            return true
        }
        return false
    }

    func countMatches(in text: NSString, range: NSRange) -> Int {
        guard let group = rule.valueGroup else {
            return regex.numberOfMatches(in: text as String, options: [], range: range)
        }
        var surviving = 0
        regex.enumerateMatches(in: text as String, options: [], range: range) { match, _, _ in
            guard let match, group < match.numberOfRanges else { return }
            let r = match.range(at: group)
            guard r.location != NSNotFound else { return }
            if !Scanner.isPlaceholder(text.substring(with: r)) { surviving += 1 }
        }
        return surviving
    }
}
