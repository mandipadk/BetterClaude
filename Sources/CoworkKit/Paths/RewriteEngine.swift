import Foundation

/// What one rewrite pass did.
public struct RewriteStats: Sendable, Equatable {
    /// Total substitutions across every rewritten string value.
    public let replacements: Int
    /// Number of top-level records in which at least one substitution happened.
    public let recordsTouched: Int
    /// String values left untouched because they are, or plausibly are, media payloads.
    public let skippedMediaFields: Int

    public init(replacements: Int = 0, recordsTouched: Int = 0, skippedMediaFields: Int = 0) {
        self.replacements = replacements
        self.recordsTouched = recordsTouched
        self.skippedMediaFields = skippedMediaFields
    }

    public static let zero = RewriteStats()

    public var isEmpty: Bool { replacements == 0 }
}

/// Applies a ``RewriteMap`` to parsed JSON records.
///
/// Everything here operates on the parsed tree. Rewriting the serialized bytes of a
/// transcript — with `sed`, a line-oriented replace, or a regex over the raw file — is the
/// obvious shortcut and it is how base64 attachments get silently corrupted: a screenshot in
/// a Cowork transcript is a single ~180 KB string, and any needle that happens to occur
/// inside it, or any change to escaping, destroys the image with no error at read time.
///
/// Two invariants follow from that and are enforced below rather than left to callers:
/// object **keys** are never rewritten (some tool results key their output by file path, and
/// rewriting a key can collide with a key that already exists and drop a value), and media
/// payloads are never rewritten (see ``RewriteEngine/isOpaquePayload(_:)``).
public enum RewriteEngine {

    public static func apply(_ map: RewriteMap, to record: JSONValue) -> (JSONValue, RewriteStats) {
        var counters = Counters()
        let rewritten = rewrite(record, map, &counters)
        let stats = RewriteStats(replacements: counters.replacements,
                                 recordsTouched: counters.replacements > 0 ? 1 : 0,
                                 skippedMediaFields: counters.skipped)
        return (rewritten, stats)
    }

    public static func apply(_ map: RewriteMap, to records: [JSONValue]) -> ([JSONValue], RewriteStats) {
        var total = 0
        var touched = 0
        var skipped = 0
        var out = records

        for index in records.indices {
            var counters = Counters()
            out[index] = rewrite(records[index], map, &counters)
            total += counters.replacements
            skipped += counters.skipped
            if counters.replacements > 0 { touched += 1 }
        }

        return (out, RewriteStats(replacements: total, recordsTouched: touched, skippedMediaFields: skipped))
    }

    /// Count occurrences of each needle across parsed records, skipping media, for
    /// verification.
    ///
    /// Counts **string values only**, matching exactly what ``apply(_:to:)-(RewriteMap,[JSONValue])``
    /// is willing to change, so a post-transfer check of "did every old path disappear" is
    /// answerable. Every needle appears in the result, including those with a zero count.
    /// Use ``countOccurrencesInKeys(of:in:)`` to detect paths that are stuck in key
    /// position — those are a reporting case, not something this engine will rewrite.
    public static func countOccurrences(of needles: [String], in records: [JSONValue]) -> [String: Int] {
        var totals = [String: Int](minimumCapacity: needles.count)
        for needle in needles { totals[needle] = 0 }
        let live = needles.filter { !$0.isEmpty }
        guard !live.isEmpty else { return totals }

        for record in records {
            visitStrings(record) { value in
                for needle in live {
                    let n = RewriteMap.occurrences(of: needle, in: value)
                    if n > 0 { totals[needle, default: 0] += n }
                }
            }
        }
        return totals
    }

    /// Occurrences of each needle in object *keys*. Always zero in healthy data; a nonzero
    /// count means a transfer will leave a dangling path that this engine deliberately will
    /// not fix, and should be surfaced to the user.
    public static func countOccurrencesInKeys(of needles: [String], in records: [JSONValue]) -> [String: Int] {
        var totals = [String: Int](minimumCapacity: needles.count)
        for needle in needles { totals[needle] = 0 }
        let live = needles.filter { !$0.isEmpty }
        guard !live.isEmpty else { return totals }

        func walk(_ value: JSONValue) {
            switch value {
            case .array(let items):
                for item in items { walk(item) }
            case .object(let object):
                for (key, child) in object.orderedPairs {
                    for needle in live {
                        let n = RewriteMap.occurrences(of: needle, in: key)
                        if n > 0 { totals[needle, default: 0] += n }
                    }
                    walk(child)
                }
            default:
                break
            }
        }

        for record in records { walk(record) }
        return totals
    }

    // MARK: - Media

    /// True for `{"type": "image"|"document", "source": {"type": "base64", "data": …}}`.
    ///
    /// This is the structural guard; it is exact, and it is what keeps screenshot and PDF
    /// attachments byte-identical across a transfer.
    public static func isMediaContainer(_ object: JSONObject) -> Bool {
        guard let kind = object["type"]?.stringValue, kind == "image" || kind == "document" else { return false }
        guard let source = object["source"]?.objectValue else { return false }
        guard source["type"]?.stringValue == "base64" else { return false }
        return source["data"]?.stringValue != nil
    }

    /// Heuristic backstop for payloads that are not in the canonical media shape — inlined
    /// data URIs, and raw base64 that a tool result embedded as a bare string.
    ///
    /// Deliberately conservative, because a false positive means a real path silently fails
    /// to be rewritten. A string qualifies only if it is longer than 256 bytes, draws
    /// entirely from the base64 alphabet (standard and URL-safe, plus line breaks), mixes
    /// upper case, lower case and digits the way encoded binary does, and is less than 10%
    /// slashes — encoded binary is about 1.5% slashes, a filesystem path is far more.
    public static func isOpaquePayload(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count > 256 else { return false }

        if s.hasPrefix("data:"), s.contains(";base64,") { return true }

        var hasUpper = false
        var hasLower = false
        var hasDigit = false
        var slashes = 0

        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): hasUpper = true
            case UInt8(ascii: "a")...UInt8(ascii: "z"): hasLower = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"): hasDigit = true
            case UInt8(ascii: "/"): slashes += 1
            case UInt8(ascii: "+"), UInt8(ascii: "="), UInt8(ascii: "-"), UInt8(ascii: "_"),
                 0x0A, 0x0D:
                break
            default:
                return false
            }
        }

        guard hasUpper, hasLower, hasDigit else { return false }
        return slashes * 10 < bytes.count
    }

    // MARK: - Walk

    private struct Counters {
        var replacements = 0
        var skipped = 0
    }

    private static func rewrite(_ value: JSONValue, _ map: RewriteMap, _ counters: inout Counters) -> JSONValue {
        switch value {
        case .string(let s):
            if isOpaquePayload(s) {
                counters.skipped += 1
                return value
            }
            let (rewritten, n) = map.apply(to: s)
            guard n > 0 else { return value }
            counters.replacements += n
            return .string(rewritten)

        case .array(let items):
            guard !items.isEmpty else { return value }
            var out = items
            for index in items.indices {
                out[index] = rewrite(items[index], map, &counters)
            }
            return .array(out)

        case .object(let object):
            let isMedia = isMediaContainer(object)
            var out = JSONObject()
            for (key, child) in object.orderedPairs {
                if isMedia, key == "source", let source = child.objectValue {
                    out[key] = .object(rewriteMediaSource(source, map, &counters))
                } else {
                    out[key] = rewrite(child, map, &counters)
                }
            }
            return .object(out)

        default:
            return value
        }
    }

    /// Rewrites everything in a media `source` except `data`, which is passed through by
    /// identity. `media_type` and any future sibling keys are ordinary values.
    private static func rewriteMediaSource(_ source: JSONObject, _ map: RewriteMap,
                                           _ counters: inout Counters) -> JSONObject {
        var out = JSONObject()
        for (key, child) in source.orderedPairs {
            if key == "data", case .string = child {
                counters.skipped += 1
                out[key] = child
            } else {
                out[key] = rewrite(child, map, &counters)
            }
        }
        return out
    }

    /// Visits every string value the rewriter would consider, applying the same media
    /// exclusions, so counts taken before and after a rewrite are comparable.
    private static func visitStrings(_ value: JSONValue, _ body: (String) -> Void) {
        switch value {
        case .string(let s):
            if isOpaquePayload(s) { return }
            body(s)

        case .array(let items):
            for item in items { visitStrings(item, body) }

        case .object(let object):
            let isMedia = isMediaContainer(object)
            for (key, child) in object.orderedPairs {
                if isMedia, key == "source", let source = child.objectValue {
                    for (sourceKey, sourceChild) in source.orderedPairs where sourceKey != "data" {
                        visitStrings(sourceChild, body)
                    }
                } else {
                    visitStrings(child, body)
                }
            }

        default:
            break
        }
    }
}
