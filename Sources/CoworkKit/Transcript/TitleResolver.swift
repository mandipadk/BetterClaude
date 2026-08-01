import Foundation

/// Where a session's displayed title came from.
///
/// The distinction is not cosmetic: `customTitle` and `aiTitle` are titles someone or
/// something deliberately assigned, while the remaining cases are salvage from whatever
/// text happened to be near the top of the file. A transfer tool should preserve the
/// former and is free to recompute the latter.
public enum TitleSource: String, Sendable {
    case customTitle
    case aiTitle
    case lastPrompt
    case firstPrompt
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

    /// Fallback titles derived from message bodies are cut here. Explicitly assigned
    /// titles (`customTitle`, `aiTitle`, `lastPrompt`) are used verbatim — the writer
    /// already chose their length.
    public static let fallbackLimit = 200

    public static func resolve(head: Data, tail: Data) -> (title: String, source: TitleSource) {
        let headRecords = parseWindow(head)
        let tailRecords = parseWindow(tail)
        // Head first, then tail, because "last occurrence wins" means latest in file order.
        // When the file is smaller than one window the two overlap and records repeat; that
        // is harmless under last-wins.
        let allRecords = headRecords + tailRecords

        if let title = lastString(in: allRecords, key: "customTitle") {
            return (title, .customTitle)
        }
        if let title = lastString(in: allRecords, key: "aiTitle") {
            return (title, .aiTitle)
        }
        if let title = lastString(in: allRecords, key: "lastPrompt") {
            return (title, .lastPrompt)
        }
        for record in headRecords {
            if let text = userMessageText(record), let title = normalize(text, limit: fallbackLimit) {
                return (title, .firstPrompt)
            }
        }
        for record in headRecords where !isSummary(record) {
            if let raw = firstStringValue(in: record, forKey: "content"),
               let title = normalize(raw, limit: fallbackLimit) {
                return (title, .contentFallback)
            }
        }
        for record in headRecords where !isSummary(record) {
            if let raw = firstStringValue(in: record, forKey: "text"),
               let title = normalize(raw, limit: fallbackLimit) {
                return (title, .contentFallback)
            }
        }
        return (placeholder, .none)
    }

    // MARK: - Window parsing

    /// Parse whole lines out of a byte window, discarding anything unparseable.
    static func parseWindow(_ data: Data) -> [JSONValue] {
        var out: [JSONValue] = []
        for line in Transcript.splitLines(data) where !line.isEmpty {
            if let value = try? JSONValue.parse(line) { out.append(value) }
        }
        return out
    }

    // MARK: - Candidate extraction

    private static func lastString(in records: [JSONValue], key: String) -> String? {
        var found: String?
        for record in records {
            if let s = record[key]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found = s
            }
        }
        guard let found else { return nil }
        return normalize(found, limit: nil)
    }

    /// A `summary` record carries a model-written recap of a *compacted* conversation. It
    /// sits near the top of the file, so a naive "first text near the head" scan picks it
    /// up in preference to the actual opening prompt — which is why the fallback scans
    /// skip it explicitly rather than relying on key names not colliding.
    private static func isSummary(_ record: JSONValue) -> Bool {
        record["type"]?.stringValue == "summary"
    }

    /// The user-visible text of a `type:"user"` record, or `nil` if the record is not one
    /// a human typed.
    ///
    /// Tool results are delivered as `type:"user"` records too; so are the caveat and
    /// slash-command wrappers, which mark themselves `isMeta`. Neither is a prompt.
    static func userMessageText(_ record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "user" else { return nil }
        guard record["isMeta"]?.boolValue != true else { return nil }
        guard let content = record["message"]?["content"] else { return nil }

        switch content {
        case .string(let s):
            return s
        case .array(let blocks):
            if blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return nil }
            let texts = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        default:
            return nil
        }
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
