import CryptoKit
import Foundation

/// Keys and tokens that ended up in a conversation: pasted in, printed by a command, or
/// written by Claude. Conversations are plain text on disk, so each one found is a key to
/// rotate.
///
/// A key is never shown or kept whole. Findings hold a masked form and a SHA-256 fingerprint,
/// which is enough to count where the same key appears and to remember it was dealt with.
public enum SecretSweep {

    public struct Kind: Sendable, Hashable {
        public let id: String
        public let name: String
        /// Where to revoke it.
        public let rotateURL: URL?
        let prefixes: [String]
        let pattern: String
    }

    public static let kinds: [Kind] = [
        Kind(id: "anthropic", name: "Anthropic API key", rotateURL: URL(string: "https://console.anthropic.com/settings/keys"),
             prefixes: ["sk-ant-"], pattern: #"sk-ant-(?:api|admin|oat|ort)\d\d-[A-Za-z0-9_\-]{40,200}(?![A-Za-z0-9_\-])"#),
        Kind(id: "openai", name: "OpenAI API key", rotateURL: URL(string: "https://platform.openai.com/api-keys"),
             prefixes: ["sk-"], pattern: #"sk-(?:proj-|svcacct-|admin-)?(?!ant-)[A-Za-z0-9_\-]{32,180}(?![A-Za-z0-9_\-])"#),
        Kind(id: "github", name: "GitHub token", rotateURL: URL(string: "https://github.com/settings/tokens"),
             prefixes: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"], pattern: #"gh[pousr]_[A-Za-z0-9]{36,80}(?![A-Za-z0-9])"#),
        Kind(id: "github-pat", name: "GitHub token", rotateURL: URL(string: "https://github.com/settings/tokens"),
             prefixes: ["github_pat_"], pattern: #"github_pat_[A-Za-z0-9_]{60,120}(?![A-Za-z0-9_])"#),
        Kind(id: "aws", name: "AWS access key", rotateURL: URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials"),
             prefixes: ["AKIA", "ASIA"], pattern: #"(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"#),
        Kind(id: "slack", name: "Slack token", rotateURL: URL(string: "https://api.slack.com/apps"),
             prefixes: ["xox"], pattern: #"xox[baprs]-[A-Za-z0-9\-]{20,120}(?![A-Za-z0-9\-])"#),
        Kind(id: "stripe", name: "Stripe secret key", rotateURL: URL(string: "https://dashboard.stripe.com/apikeys"),
             prefixes: ["k_live_"], pattern: #"[sr]k_live_[A-Za-z0-9]{20,120}(?![A-Za-z0-9])"#),
        Kind(id: "google", name: "Google API key", rotateURL: URL(string: "https://console.cloud.google.com/apis/credentials"),
             prefixes: ["AIza"], pattern: #"AIza[0-9A-Za-z_\-]{35}(?![0-9A-Za-z_\-])"#),
        Kind(id: "huggingface", name: "Hugging Face token", rotateURL: URL(string: "https://huggingface.co/settings/tokens"),
             prefixes: ["hf_"], pattern: #"hf_[A-Za-z0-9]{34,40}(?![A-Za-z0-9])"#),
        Kind(id: "npm", name: "npm token", rotateURL: URL(string: "https://docs.npmjs.com/revoking-access-tokens"),
             prefixes: ["npm_"], pattern: #"npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"#),
        Kind(id: "private-key", name: "Private key", rotateURL: nil,
             // Line breaks as themselves, as JSON's \n, or escaped again inside a JSON string.
             prefixes: ["PRIVATE KEY-----"], pattern: #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----(?:\\+[nr]|\s)+[A-Za-z0-9+/=]{40}"#),
    ]

    static let expressions: [(Kind, NSRegularExpression)] = kinds.compactMap { kind in
        // Not the tail of a longer word: "task-…" isn't an OpenAI key. A JSON escape just
        // before it (`\n`, `\t`, `\u0022`) ends the word before, though it ends in a letter.
        let boundary = #"(?:(?<![A-Za-z0-9_])|(?<=\\[nrtbf])|(?<=\\u[0-9A-Fa-f]{4}))"#
        return (try? NSRegularExpression(pattern: boundary + kind.pattern)).map { (kind, $0) }
    }

    /// The rest of a private key after what its pattern matched, through its END line.
    static let privateKeyBody = try? NSRegularExpression(
        pattern: #"\G(?:[A-Za-z0-9+/=]|\\+[nr]|\s)*(?:-----END (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----)?"#)

    /// Where in a conversation a key appeared.
    public enum Source: String, Sendable, Codable {
        case pasted, commandOutput, claude, unknown

        public var description: String {
            switch self {
            case .pasted: return "You pasted it"
            case .commandOutput: return "A command or tool printed it"
            case .claude: return "Claude wrote it"
            case .unknown: return "In the conversation"
            }
        }
    }

    public struct Sighting: Sendable, Equatable {
        public let conversationID: String
        public let source: Source
    }

    public struct Finding: Sendable, Identifiable, Equatable {
        public var id: String { fingerprint }
        public let kind: Kind
        /// The first few and last four characters: enough to recognise, not to use.
        public let masked: String
        public let fingerprint: String
        public var sightings: [Sighting]

        public var conversations: Set<String> { Set(sightings.map(\.conversationID)) }

        public static func == (a: Finding, b: Finding) -> Bool {
            a.fingerprint == b.fingerprint && a.sightings == b.sightings
        }
    }

    public static func mask(_ secret: String, kind: Kind) -> String {
        if kind.id == "private-key" { return "-----BEGIN PRIVATE KEY-----" }
        let head = secret.prefix(kind.id == "anthropic" ? 13 : min(8, secret.count / 3))
        return "\(head)…\(secret.suffix(4))"
    }

    public static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every key in `text`, with where it sits.
    static func matches(in text: String) -> [(kind: Kind, range: NSRange, value: String)] {
        let ns = text as NSString
        var found: [(Kind, NSRange, String)] = []
        var taken = IndexSet()
        for (kind, expression) in expressions where kind.prefixes.contains(where: text.contains) {
            for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                guard !taken.intersects(integersIn: range.location..<(range.location + range.length)) else { continue }
                taken.insert(integersIn: range.location..<(range.location + range.length))
                found.append((kind, range, ns.substring(with: range)))
            }
        }
        return found
    }

    /// `text` with every key masked: for what Claude reads back through its history tools and
    /// for exports.
    public static func redact(_ text: String) -> String {
        let hits = matches(in: text)
        guard !hits.isEmpty else { return text }
        let result = NSMutableString(string: text)
        let length = (text as NSString).length
        for hit in hits.sorted(by: { $0.range.location > $1.range.location }) {
            var range = hit.range
            // A private key's pattern stops after its first line; the rest is just as secret.
            if hit.kind.id == "private-key", let body = privateKeyBody?.firstMatch(
                in: text, options: [.anchored], range: NSRange(location: NSMaxRange(range), length: length - NSMaxRange(range))) {
                range.length += body.range.length
            }
            result.replaceCharacters(in: range, with: "[\(hit.kind.name.lowercased()) hidden]")
        }
        return result as String
    }

    /// Every conversation file on the Mac: Claude's transcripts and their sub-agents', Codex
    /// sessions and imported claude.ai conversations.
    public static func files(in snapshot: CatalogSnapshot) -> [(conversationID: String, url: URL)] {
        snapshot.conversations.flatMap { conversation -> [(conversationID: String, url: URL)] in
            guard let url = conversation.transcriptURL ?? conversation.external?.fileURL else { return [] }
            let agents = conversation.transcriptURL.map { Subagents.transcripts(beside: $0) } ?? []
            return [(conversation.id, url)] + agents.map { (conversation.id, $0.url) }
        }
    }

    /// The prefix that names a kept copy in place of a conversation id.
    public static let keptPrefix = "kept:"

    /// Kept copies worth sweeping: every copy of a conversation Claude Code has deleted, since
    /// they're the only plaintext of it left, and the earlier copies of one that was rewritten.
    /// Each is named ``keptPrefix`` and its entry's key.
    public static func keptFiles(_ entries: [Vault.Entry]) -> [(conversationID: String, url: URL)] {
        entries.flatMap { entry -> [(conversationID: String, url: URL)] in
            let versions = entry.sourceExists ? entry.versions.dropLast() : entry.versions[...]
            return versions.map { (keptPrefix + entry.key, Vault.objectURL($0.sha256)) }
                .filter { FileManager.default.fileExists(atPath: $0.1.path) }
        }
    }

    /// Sweeps conversation files. The bytes are searched for each kind's prefix and only a
    /// short stretch around a hit is matched, so a large history takes seconds.
    public static func sweep(_ files: [(conversationID: String, url: URL)],
                             progress: (@Sendable (Int, Int) -> Void)? = nil) -> [Finding] {
        let needles = Array(Set(kinds.flatMap(\.prefixes))).map { Array($0.utf8) }
        // Each file on its own core; what each finds is merged under a lock.
        let merged = Locked([String: Finding]())
        let done = Locked(0)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            var local: [(Kind, String, String, Source)] = []
            if let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) {
                for hit in candidates(in: data, needles: needles) {
                    let window = String(decoding: data[hit.window], as: UTF8.self)
                    var hits = matches(in: window)
                    guard !hits.isEmpty else { continue }
                    // A key running on past the window would be taken cut short: match its whole line.
                    let length = (window as NSString).length
                    if hits.contains(where: { NSMaxRange($0.range) == length }),
                       hit.window.upperBound < data.count, data[hit.window.upperBound] != 0x0A {
                        // Other keys on the line come along too; each is counted once all the same.
                        hits = matches(in: String(decoding: data[line(around: hit.at, in: data)], as: UTF8.self))
                    }
                    let source = Self.source(of: data[line(around: hit.at, in: data)])
                    for match in hits { local.append((match.kind, match.value, fingerprint(match.value), source)) }
                }
            }
            merged.withLock { findings in
                for (kind, value, print, source) in local {
                    var finding = findings[print] ?? Finding(kind: kind, masked: mask(value, kind: kind), fingerprint: print, sightings: [])
                    let sighting = Sighting(conversationID: file.conversationID, source: source)
                    if !finding.sightings.contains(sighting) { finding.sightings.append(sighting) }
                    findings[print] = finding
                }
            }
            let count = done.withLock { value -> Int in value += 1; return value }
            progress?(count, files.count)
        }
        return merged.withLock { $0 }.values.sorted { $0.sightings.count > $1.sightings.count }
    }

    /// The line holding byte `at`: found only for a real match, since lines can be megabytes.
    static func line(around at: Int, in data: Data) -> Range<Int> {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Int> in
            var start = at, end = at
            while start > 0, raw[start - 1] != 0x0A { start -= 1 }
            while end < raw.count, raw[end] != 0x0A { end += 1 }
            return start..<end
        }
    }

    /// Where each prefix occurs, with a short stretch around it to match.
    static func candidates(in data: Data, needles: [[UInt8]]) -> [(window: Range<Int>, at: Int)] {
        var found: [(Range<Int>, Int)] = []
        var windows = IndexSet()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            for needle in needles {
                var position = 0
                while position < count, let hit = needle.withUnsafeBytes({ memmem(base + position, count - position, $0.baseAddress, needle.count) }) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    position = at + needle.count
                    // Keys start a word: "task-" and "desk-" aren't worth decoding. (Stripe's
                    // prefix starts mid-word by design, and a key block's by its dashes.)
                    if at > 0, needle.first != UInt8(ascii: "k"), needle.first != UInt8(ascii: "P"),
                       isWordByte(raw[at - 1]), !endsEscape(raw, at: at) { continue }
                    // Anthropic keys contain "sk-", so one hit's window covers the other.
                    if windows.contains(at) { continue }
                    // Within its own line: a key in the next record belongs to that record.
                    var start = at, end = at
                    while start > max(0, at - 40), raw[start - 1] != 0x0A { start -= 1 }
                    while end < min(count, at + 400), raw[end] != 0x0A { end += 1 }
                    let window = start..<end
                    windows.insert(integersIn: window)
                    found.append((window, at))
                }
            }
        }
        return found
    }

    static func isWordByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
    }

    /// Whether a JSON escape, `\n` or `\u0022`, ends just before `at`.
    static func endsEscape(_ raw: UnsafeRawBufferPointer, at: Int) -> Bool {
        let backslash = UInt8(ascii: "\\")
        if at >= 2, raw[at - 2] == backslash, "nrtbf".utf8.contains(raw[at - 1]) { return true }
        guard at >= 6, raw[at - 6] == backslash, raw[at - 5] == UInt8(ascii: "u") else { return false }
        return (at - 4..<at).allSatisfy { index in
            let byte = raw[index] | 0x20
            return (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    /// Who put the key there, from the record around it.
    static func source(of line: Data) -> Source {
        guard let record = try? JSONValue.parse(Data(line)) else { return .unknown }
        // Codex rollouts wrap what was said in a payload.
        let payload = record["payload"] ?? record
        let type = record["type"]?.stringValue
        if type == "assistant" || payload["role"]?.stringValue == "assistant" { return .claude }
        if record["toolUseResult"] != nil || payload["type"]?.stringValue?.hasSuffix("_output") == true { return .commandOutput }
        let blocks = record["message"]?["content"]?.arrayValue ?? []
        if blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return .commandOutput }
        if type == "user" || payload["role"]?.stringValue == "user" { return .pasted }
        return .unknown
    }
}

/// Keys someone has rotated, by fingerprint only.
public enum HandledSecrets {
    static func url(paths: HostPaths) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Secrets/handled.json")
    }

    public static func load(paths: HostPaths = .current) -> Set<String> {
        guard let data = try? Data(contentsOf: url(paths: paths)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public static func save(_ fingerprints: Set<String>, paths: HostPaths = .current) throws {
        let target = url(paths: paths)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWrite.write(try JSONEncoder().encode(fingerprints.sorted()), to: target)
    }
}

/// A value shared between threads, behind a lock (Mutex needs macOS 15).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
