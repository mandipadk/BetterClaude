import CryptoKit
import Foundation

/// A Claude Code transcript: one JSON object per line, in the order the CLI appended them.
///
/// Line order is not merely cosmetic. The logical conversation is a tree threaded by
/// `parentUuid`, and bookkeeping records (`ai-title`, `last-prompt`, `mode`, …) sit outside
/// that tree entirely — but the resume picker resolves a session's title by scanning the
/// first and last 64 KiB of the *file*, so which records land in those windows depends
/// purely on line order. Rewriting a transcript in "conversation order" silently changes
/// its title. ``records`` therefore preserves the source order exactly, and ``write(to:)``
/// emits it unchanged.
public struct Transcript: Sendable {
    private var storage: [JSONValue]

    /// 1-based line numbers that were non-empty but did not parse as JSON.
    ///
    /// A single truncated line — the usual result of a crash mid-append — must not make an
    /// otherwise intact 40 MB transcript unreadable, so loading collects these and
    /// continues. They are *not* preserved by ``write(to:)``; a caller that cares about
    /// losing them should refuse to write when this is non-empty.
    public let malformedLineNumbers: [Int]

    /// Where this transcript was read from, when it was read from disk.
    public let sourceURL: URL?

    public var records: [JSONValue] { storage }

    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TranscriptError.unreadable(url: url, underlying: String(describing: error))
        }
        var parsed: [JSONValue] = []
        var malformed: [Int] = []
        var lineNumber = 0
        for line in Self.splitLines(data) {
            lineNumber += 1
            guard !line.isEmpty else { continue }
            do {
                parsed.append(try JSONValue.parse(line))
            } catch {
                malformed.append(lineNumber)
            }
        }
        self.storage = parsed
        self.malformedLineNumbers = malformed
        self.sourceURL = url
    }

    public init(records: [JSONValue]) {
        self.storage = records
        self.malformedLineNumbers = []
        self.sourceURL = nil
    }

    // MARK: - Writing

    /// Serialize and install atomically: write a sibling temp file, then `rename(2)`.
    ///
    /// The temp file must be a sibling because `rename(2)` is only atomic within a
    /// filesystem, and Claude Desktop's session workspaces are routinely on a different
    /// volume from `NSTemporaryDirectory()`.
    public func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try serializedData().write(to: tempURL)
        } catch {
            throw TranscriptError.writeFailed(url: tempURL, underlying: String(describing: error))
        }

        let moved = tempURL.withUnsafeFileSystemRepresentation { source -> Int32 in
            url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return rename(source, destination)
            }
        }
        guard moved == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw TranscriptError.renameFailed(
                from: tempURL, to: url, code: code, message: String(cString: strerror(code)))
        }
    }

    /// Exactly the bytes ``write(to:)`` installs: one compact JSON object per line, each
    /// line terminated by `\n` including the last.
    public func serializedData() -> Data {
        var data = Data()
        data.reserveCapacity(storage.count * 512)
        for record in storage {
            data.append(record.serialized())
            data.append(0x0A)
        }
        return data
    }

    // MARK: - Mutation

    /// Rewrite every record in place, dropping those for which `f` returns `nil`.
    public mutating func mapRecords(_ f: (JSONValue) -> JSONValue?) {
        storage = storage.compactMap(f)
    }

    // MARK: - Structure

    public var recordTypeHistogram: [String: Int] {
        var histogram: [String: Int] = [:]
        for record in storage {
            histogram[record["type"]?.stringValue ?? "<untyped>", default: 0] += 1
        }
        return histogram
    }

    /// Record types that live outside the `parentUuid` tree.
    ///
    /// These carry no `parentUuid` by design and must not be counted as conversation roots,
    /// or every transcript looks like a dozen disconnected fragments.
    public static let bookkeepingRecordTypes: Set<String> = [
        "queue-operation", "last-prompt", "ai-title", "custom-title", "summary", "mode",
    ]

    /// Roots and dangling parents in the `uuid`/`parentUuid` graph.
    ///
    /// A healthy transcript has exactly one root and no orphans. More than one root means
    /// two conversations were concatenated; an orphan means a record's parent was dropped,
    /// which is what a naive filtering transfer produces.
    public func chainIntegrity() -> (roots: Int, orphans: [String]) {
        var knownUuids = Set<String>()
        for record in storage {
            if let uuid = record["uuid"]?.stringValue { knownUuids.insert(uuid) }
        }

        var roots = 0
        var orphans: [String] = []
        var seenOrphans = Set<String>()
        for record in storage {
            guard record["uuid"]?.stringValue != nil else { continue }
            let type = record["type"]?.stringValue ?? ""
            guard !Self.bookkeepingRecordTypes.contains(type) else { continue }

            guard let parent = record["parentUuid"], !parent.isNull else {
                roots += 1
                continue
            }
            guard let parentUuid = parent.stringValue else { continue }
            if !knownUuids.contains(parentUuid), seenOrphans.insert(parentUuid).inserted {
                orphans.append(parentUuid)
            }
        }
        return (roots, orphans)
    }

    public func stats() -> ChatStats {
        let (roots, orphans) = chainIntegrity()

        var chainRecordCount = 0
        var userTurns = 0
        var assistantTurns = 0
        var timestamps: [Date] = []
        var sessionIds = OrderedStrings()
        var entrypoints = OrderedStrings()
        var gitBranches = OrderedStrings()
        var mediaBlocks = 0
        var mediaBytes = 0

        for record in storage {
            if record["uuid"]?.stringValue != nil { chainRecordCount += 1 }
            switch record["type"]?.stringValue {
            case "user": userTurns += 1
            case "assistant": assistantTurns += 1
            default: break
            }
            if let raw = record["timestamp"]?.stringValue, let date = Self.parseTimestamp(raw) {
                timestamps.append(date)
            }
            if let value = record["sessionId"]?.stringValue { sessionIds.insert(value) }
            if let value = record["entrypoint"]?.stringValue { entrypoints.insert(value) }
            if let value = record["gitBranch"]?.stringValue, !value.isEmpty { gitBranches.insert(value) }
            Self.accumulateInlineMedia(record, blocks: &mediaBlocks, bytes: &mediaBytes)
        }

        return ChatStats(
            recordCount: storage.count,
            chainRecordCount: chainRecordCount,
            userTurns: userTurns,
            assistantTurns: assistantTurns,
            firstTimestamp: timestamps.min(),
            lastTimestamp: timestamps.max(),
            orphanParentUuids: orphans.count,
            rootCount: roots,
            inlineMediaBlocks: mediaBlocks,
            inlineMediaBytes: mediaBytes,
            sessionIdsSeen: sessionIds.values,
            entrypointsSeen: entrypoints.values,
            gitBranchesSeen: gitBranches.values)
    }

    // MARK: - Title

    public func resolvedTitle() -> (title: String, source: TitleSource) {
        let data = serializedData()
        let window = Self.pickerWindowBytes
        let headEnd = min(data.count, window)
        let tailStart = max(headEnd, data.count - window)
        let head = data.subdata(in: 0..<headEnd)
        let tail = data.subdata(in: tailStart..<data.count)
        return TitleResolver.resolve(head: head, tail: tail)
    }

    // MARK: - Picker filter

    /// The window Claude Code scans at each end of the file.
    public static let pickerWindowBytes = 65_536

    /// Tokens whose presence anywhere in the head or tail window removes the session from
    /// the resume picker — silently, with no error and no log line.
    ///
    /// The filter is a byte scan over the raw file, not a check on parsed fields, so a
    /// transcript that merely *quotes* another transcript inside a tool result is filtered
    /// just as hard as one that really is a sidechain. That quoted form arrives with its
    /// quotes JSON-escaped (`\"isSidechain\":true`), which is why each `"` below is matched
    /// with an optional leading backslash.
    public func pickerFilterViolations(windowBytes: Int = pickerWindowBytes) -> [PickerViolation] {
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(storage.count)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(storage.count * 512)
        for record in storage {
            lineStarts.append(bytes.count)
            bytes.append(contentsOf: record.serialized())
            bytes.append(0x0A)
        }

        let headEnd = min(bytes.count, max(0, windowBytes))
        let tailStart = max(headEnd, bytes.count - max(0, windowBytes))

        var violations: [PickerViolation] = []
        var seen = Set<String>()

        func scan(_ range: Range<Int>, window: String) {
            guard !range.isEmpty else { return }
            for offset in range {
                let byte = bytes[offset]
                guard byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                for token in PickerFilterToken.all where token.matches(bytes, at: offset) {
                    let index = Self.recordIndex(forByteOffset: offset, lineStarts: lineStarts)
                    let key = "\(index)|\(token.name)|\(window)"
                    if seen.insert(key).inserted {
                        violations.append(
                            PickerViolation(recordIndex: index, token: token.name, window: window))
                    }
                }
            }
        }

        scan(0..<headEnd, window: "head")
        scan(tailStart..<bytes.count, window: "tail")
        return violations
    }

    // MARK: - Fingerprints

    /// `uuid` → SHA-256 of the record's key-sorted `message`.
    ///
    /// Sorting keys makes the digest independent of the key order a rewrite happens to
    /// produce, so a round-trip test can assert that inline media survived transfer byte
    /// for byte without also asserting that nothing reordered.
    public func contentFingerprints() -> [String: String] {
        var result: [String: String] = [:]
        for record in storage {
            guard let uuid = record["uuid"]?.stringValue else { continue }
            let message = record["message"] ?? .null
            let digest = SHA256.hash(data: message.serializedCanonical())
            result[uuid] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    // MARK: - Helpers

    /// Split on `\n`, keeping every line including empty ones so line numbers stay true.
    /// A trailing newline does not produce a final empty line.
    static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                lines.append(data.subdata(in: start..<index))
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }

    static func recordIndex(forByteOffset offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Count `{"type":"image"|"document","source":{"data":…}}` blocks anywhere in the tree.
    ///
    /// The recursive walk is deliberate: media blocks appear in `message.content`, but also
    /// nested inside `tool_result` content and inside `toolUseResult` payloads.
    static func accumulateInlineMedia(_ value: JSONValue, blocks: inout Int, bytes: inout Int) {
        switch value {
        case .object(let object):
            let type = object["type"]?.stringValue
            if type == "image" || type == "document",
               let data = object["source"]?["data"]?.stringValue {
                blocks += 1
                bytes += data.utf8.count
            }
            for pair in object.orderedPairs {
                accumulateInlineMedia(pair.value, blocks: &blocks, bytes: &bytes)
            }
        case .array(let items):
            for item in items { accumulateInlineMedia(item, blocks: &blocks, bytes: &bytes) }
        default:
            break
        }
    }

    /// Parse an ISO-8601 timestamp with or without fractional seconds.
    ///
    /// Every timestamp observed on disk is `…Z` with milliseconds, but the CLI's writer has
    /// changed format before and a timestamp that fails to parse silently drops a record
    /// out of the date range, so both spellings are tried.
    public static func parseTimestamp(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601WithFraction) { return date }
        if let date = try? Date(raw, strategy: .iso8601Plain) { return date }
        return nil
    }
}

// MARK: - Supporting types

public struct ChatStats: Sendable, Equatable {
    public let recordCount: Int
    /// Records carrying a `uuid` — i.e. participating in the conversation tree.
    public let chainRecordCount: Int
    public let userTurns: Int
    public let assistantTurns: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let orphanParentUuids: Int
    public let rootCount: Int
    public let inlineMediaBlocks: Int
    public let inlineMediaBytes: Int
    /// Distinct values in order of first appearance; the transcript's own id sorts first.
    public let sessionIdsSeen: [String]
    public let entrypointsSeen: [String]
    public let gitBranchesSeen: [String]

    public init(recordCount: Int, chainRecordCount: Int, userTurns: Int, assistantTurns: Int,
                firstTimestamp: Date?, lastTimestamp: Date?, orphanParentUuids: Int,
                rootCount: Int, inlineMediaBlocks: Int, inlineMediaBytes: Int,
                sessionIdsSeen: [String], entrypointsSeen: [String], gitBranchesSeen: [String]) {
        self.recordCount = recordCount
        self.chainRecordCount = chainRecordCount
        self.userTurns = userTurns
        self.assistantTurns = assistantTurns
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.orphanParentUuids = orphanParentUuids
        self.rootCount = rootCount
        self.inlineMediaBlocks = inlineMediaBlocks
        self.inlineMediaBytes = inlineMediaBytes
        self.sessionIdsSeen = sessionIdsSeen
        self.entrypointsSeen = entrypointsSeen
        self.gitBranchesSeen = gitBranchesSeen
    }
}

/// One reason Claude Code would hide this transcript from the resume picker.
public struct PickerViolation: Sendable, Equatable {
    public let recordIndex: Int
    public let token: String
    /// `"head"` or `"tail"` — which scanned window the match landed in.
    public let window: String

    public init(recordIndex: Int, token: String, window: String) {
        self.recordIndex = recordIndex
        self.token = token
        self.window = window
    }
}

public enum TranscriptError: Error, CustomStringConvertible {
    case unreadable(url: URL, underlying: String)
    case writeFailed(url: URL, underlying: String)
    case renameFailed(from: URL, to: URL, code: Int32, message: String)

    public var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            return "could not read transcript at \(url.path): \(underlying)"
        case .writeFailed(let url, let underlying):
            return "could not write \(url.path): \(underlying)"
        case .renameFailed(let from, let to, let code, let message):
            return "could not install \(from.lastPathComponent) as \(to.path): \(message) (errno \(code))"
        }
    }
}

// MARK: - Picker token matching

/// A byte pattern matched against the raw serialized file.
struct PickerFilterToken {
    enum Segment {
        /// A `"`, optionally preceded by a backslash so escaped occurrences inside a string
        /// literal match too.
        case quote
        case literal([UInt8])
        /// A `:` with optional surrounding whitespace.
        case colon
    }

    let name: String
    let segments: [Segment]

    static let all: [PickerFilterToken] = [
        PickerFilterToken(name: "\"isSidechain\":true", segments: [
            .quote, .literal(Array("isSidechain".utf8)), .quote, .colon,
            .literal(Array("true".utf8)),
        ]),
        PickerFilterToken(name: "\"teamName\"", segments: [
            .quote, .literal(Array("teamName".utf8)), .quote,
        ]),
        PickerFilterToken(name: "\"sessionKind\"", segments: [
            .quote, .literal(Array("sessionKind".utf8)), .quote,
        ]),
        PickerFilterToken(name: "\"entrypoint\":\"sdk-cli\"", segments: [
            .quote, .literal(Array("entrypoint".utf8)), .quote, .colon,
            .quote, .literal(Array("sdk-cli".utf8)), .quote,
        ]),
    ]

    func matches(_ bytes: [UInt8], at start: Int) -> Bool {
        var cursor = start
        for segment in segments {
            switch segment {
            case .quote:
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\\") { cursor += 1 }
                guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") else { return false }
                cursor += 1
            case .literal(let literal):
                guard cursor + literal.count <= bytes.count else { return false }
                for (index, byte) in literal.enumerated() where bytes[cursor + index] != byte {
                    return false
                }
                cursor += literal.count
            case .colon:
                while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { return false }
                cursor += 1
                while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
            }
        }
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - Small utilities

/// Distinct strings in first-insertion order.
private struct OrderedStrings {
    private var seen = Set<String>()
    private(set) var values: [String] = []

    mutating func insert(_ value: String) {
        if seen.insert(value).inserted { values.append(value) }
    }
}

extension ParseStrategy where Self == Date.ISO8601FormatStyle {
    static var iso8601WithFraction: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }

    static var iso8601Plain: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    }
}
