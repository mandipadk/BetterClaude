import Foundation

/// Where a session's displayed title came from.
///
/// The distinction is not cosmetic: `agentName`, `customTitle` and `aiTitle` are titles
/// someone or something deliberately assigned, while the remaining cases are salvage from
/// whatever text happened to be near the top of the file. A transfer tool should preserve
/// the former and is free to recompute the latter.
public enum TitleSource: String, Sendable {
    case agentName
    case customTitle
    case aiTitle
    case summary
    case firstPrompt
    case lastPrompt
    case contentFallback
    case none
}

/// Recovers the title Claude Code shows for a transcript, from only the first and last
/// window of the file.
///
/// Claude Code never reads a whole `.jsonl` to build the resume picker — it reads a head
/// and a tail slice and scans those. Discovery has to do the same or listing a store with
/// a few hundred multi-megabyte transcripts becomes a multi-second stall, so the resolver
/// is written against `Data` windows rather than a parsed ``Transcript``.
///
/// The windows are arbitrary byte slices, so their outermost lines are usually truncated.
/// Truncated lines simply fail to parse and are skipped; that is the intended behaviour,
/// not a tolerated defect.
public enum TitleResolver {

    /// The literal shown when a transcript yields no usable text at all.
    public static let placeholder = "(session)"

    /// Titles taken from a prompt are cut here, and end in "…". Explicitly assigned titles
    /// are used verbatim — the writer already chose their length.
    public static let fallbackLimit = 200

    public static func resolve(head: Data, tail: Data, sidecarTitle: String? = nil) -> (title: String, source: TitleSource) {
        resolve(headLines: Transcript.splitLines(head), tailLines: Transcript.splitLines(tail),
                sidecarTitle: sidecarTitle) ?? (placeholder, .none)
    }

    /// The title from whole lines at each end of a transcript, in Claude Code's order: the
    /// agent's name, a title someone gave it, Claude's title, a compaction summary, then the
    /// first prompt. `nil` when none of them is there.
    ///
    /// Titles are appended rather than rewritten, so the newest is the last in the file: the
    /// tail is read backwards first, and the head only for what the tail lacks.
    static func resolve(headLines: [Data], tailLines: [Data], sidecarTitle: String?) -> (title: String, source: TitleSource)? {
        var found = AssignedTitles()
        found.absorb(tailLines.reversed())
        if found.customTitle == nil { found.customTitle = sidecarTitle.flatMap { normalize($0, limit: nil) } }
        found.absorb(headLines.reversed())

        if let title = found.agentName { return (title, .agentName) }
        if let title = found.customTitle { return (title, .customTitle) }
        if let title = found.aiTitle { return (title, .aiTitle) }
        if let title = found.summary { return (title, .summary) }
        let headRecords = headLines.lazy.filter { !$0.isEmpty }.compactMap { try? JSONValue.parse($0) }
        if let title = firstPrompt(in: headRecords) { return (title, .firstPrompt) }
        if let title = found.lastPrompt { return (title, .lastPrompt) }
        for key in ["content", "text"] {
            for record in headRecords where !isSummary(record) {
                if let raw = firstStringValue(in: record, forKey: key),
                   let title = normalize(raw, limit: fallbackLimit) {
                    return (title, .contentFallback)
                }
            }
        }
        return nil
    }

    /// A title someone assigned, as Claude Code keeps it beside the transcript:
    /// `<session>/custom-title.json`.
    public static func sidecarTitle(forTranscript url: URL) -> String? {
        let sidecar = url.deletingPathExtension().appendingPathComponent("custom-title.json")
        guard let data = try? Data(contentsOf: sidecar), let record = try? JSONValue.parse(data) else { return nil }
        return record["customTitle"]?.stringValue.flatMap { normalize($0, limit: nil) }
    }

    private struct AssignedTitles {
        var agentName: String?
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var lastPrompt: String?

        static let markers: [Data] = ["\"agentName\"", "\"customTitle\"", "\"aiTitle\"", "\"lastPrompt\"",
                                      "\"type\":\"summary\""].map { Data($0.utf8) }

        /// Takes the first value of each kind it meets, so lines go newest first. Lines are
        /// filtered on their raw bytes before parsing: a 64 KiB window holds dozens of large
        /// records and only a few of them carry a title.
        mutating func absorb(_ lines: some Sequence<Data>) {
            for line in lines where Self.markers.contains(where: { line.range(of: $0) != nil }) {
                guard let record = try? JSONValue.parse(line) else { continue }
                func take(_ key: String, into slot: inout String?) {
                    if slot == nil, let value = record[key]?.stringValue { slot = normalize(value, limit: nil) }
                }
                take("agentName", into: &agentName)
                take("customTitle", into: &customTitle)
                take("aiTitle", into: &aiTitle)
                take("lastPrompt", into: &lastPrompt)
                if record["type"]?.stringValue == "summary" { take("summary", into: &summary) }
            }
        }
    }

    // MARK: - First prompt

    /// Claude Code's built-in commands, which say nothing about what a session is for.
    static let builtInCommands: Set<String> = [
        "add-dir", "agents", "bug", "clear", "compact", "config", "context", "cost", "doctor", "effort", "exit",
        "export", "fast", "help", "hooks", "ide", "init", "login", "logout", "mcp", "memory", "model",
        "output-style", "permissions", "plugin", "pr-comments", "release-notes", "resume", "review", "rewind",
        "status", "statusline", "terminal-setup", "theme", "todos", "upgrade", "usage", "vim",
    ]

    /// Text a tool wrote at the start of the person's turn, or a note that they interrupted.
    static let notTyped = try! NSRegularExpression(pattern: #"^\s*(<[a-z][\w-]*[\s>]|\[Request interrupted by user)"#)

    /// The first thing the person asked, as Claude Code titles a session with no other
    /// title: a slash command as `/name arguments`, a shell command as `! command`, and
    /// anything a tool wrote skipped. A command with nothing after it, or one of Claude
    /// Code's own, is used only when nothing else is found; after that, what the person
    /// typed below something a tool put first, such as the files a Cowork prompt opens with.
    static func firstPrompt(in records: some Sequence<JSONValue>) -> String? {
        var fallback: String?
        var typedFallback: String?
        for record in records {
            guard let texts = userTexts(record) else { continue }
            for text in texts {
                if let name = InjectedContext.element("command-name", in: text) {
                    let command = name.hasPrefix("/") ? name : "/" + name
                    let arguments = InjectedContext.element("command-args", in: text) ?? ""
                    let line = arguments.isEmpty ? command : "\(command) \(arguments)"
                    if arguments.isEmpty || builtInCommands.contains(String(command.dropFirst())) {
                        if fallback == nil { fallback = clip(line) }
                        continue
                    }
                    if let title = clip(line) { return title }
                    continue
                }
                if let input = InjectedContext.element("bash-input", in: text), let title = clip("! \(input)") {
                    return title
                }
                let range = NSRange(text.startIndex..., in: text)
                if notTyped.firstMatch(in: text, range: range) != nil {
                    if typedFallback == nil {
                        typedFallback = InjectedContext.typedText(InjectedContext.parts(ofBlocks: [text])).flatMap(clip)
                    }
                    continue
                }
                if let title = clip(text) { return title }
            }
        }
        return fallback ?? typedFallback
    }

    /// The text blocks of a turn the person took, or `nil` for any other record.
    ///
    /// Tool results are delivered as `type:"user"` records too; so are the caveat and
    /// slash-command wrappers, which mark themselves `isMeta`. Neither is a prompt.
    static func userTexts(_ record: JSONValue) -> [String]? {
        guard record["type"]?.stringValue == "user", record["isMeta"]?.boolValue != true,
              record["isCompactSummary"]?.boolValue != true, let message = record["message"] else { return nil }
        return ConversationText.textBlocks(of: message)
    }

    static func clip(_ text: String) -> String? {
        guard let line = normalize(text, limit: nil) else { return nil }
        guard line.count > fallbackLimit else { return line }
        return String(line.prefix(fallbackLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A `summary` record carries a model-written recap of a *compacted* conversation. It
    /// sits near the top of the file, so a naive "first text near the head" scan picks it
    /// up in preference to the actual opening prompt — which is why the fallback scans
    /// skip it explicitly rather than relying on key names not colliding.
    private static func isSummary(_ record: JSONValue) -> Bool {
        record["type"]?.stringValue == "summary"
    }

    /// Depth-first search for the first string value stored under `key`, in key order.
    private static func firstStringValue(in value: JSONValue, forKey key: String) -> String? {
        switch value {
        case .object(let object):
            for pair in object.orderedPairs {
                if pair.key == key, case .string(let s) = pair.value { return s }
            }
            for pair in object.orderedPairs {
                if let found = firstStringValue(in: pair.value, forKey: key) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = firstStringValue(in: item, forKey: key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Normalization

    /// Collapse to a single line and trim; `nil` when nothing survives.
    static func normalize(_ raw: String, limit: Int?) -> String? {
        var collapsed = ""
        collapsed.reserveCapacity(raw.count)
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace, !collapsed.isEmpty { collapsed.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        while collapsed.hasSuffix(" ") { collapsed.removeLast() }
        guard !collapsed.isEmpty else { return nil }
        guard let limit, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
    }
}
