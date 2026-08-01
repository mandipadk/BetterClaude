import Foundation

/// A lossless JSON tree.
///
/// Cowork session metadata and Claude Code transcripts are undocumented formats that
/// accrete keys over time — `memoryGuidelinesTemplate` first appeared in sessions created
/// 2026-05-31, and older sessions lack `hostLoopMode` entirely. `Codable` silently drops
/// keys it has no property for, which would quietly strip fields from any session we
/// rewrite. Every read-modify-write path in this package therefore goes through
/// `JSONValue`, which round-trips unknown keys and preserves object key order.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Key order is preserved so rewritten files stay byte-close to the originals.
    case object(JSONObject)

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let o) = self else { return nil }
            return o[key]
        }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(exactly: d.rounded())
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }
}

/// An insertion-ordered string-keyed JSON object.
public struct JSONObject: Sendable, Equatable {
    private(set) var keys: [String]
    private var storage: [String: JSONValue]

    public init() {
        keys = []
        storage = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        keys = []
        storage = [:]
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else {
                if storage[key] != nil { keys.removeAll { $0 == key } }
                storage[key] = nil
            }
        }
    }

    public var orderedPairs: [(key: String, value: JSONValue)] {
        keys.compactMap { k in storage[k].map { (key: k, value: $0) } }
    }

    public var count: Int { keys.count }
    public func has(_ key: String) -> Bool { storage[key] != nil }
}

// MARK: - Parsing

extension JSONValue {
    public enum ParseError: Error, CustomStringConvertible {
        case malformed(String)
        case trailingBytes(offset: Int)

        public var description: String {
            switch self {
            case .malformed(let m): return "malformed JSON: \(m)"
            case .trailingBytes(let o): return "unexpected trailing bytes at offset \(o)"
            }
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError.trailingBytes(offset: parser.offset) }
        return value
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }
}

/// A minimal recursive-descent JSON parser.
///
/// `JSONSerialization` is not usable here: it returns `NSDictionary`, which discards key
/// order, and collapses integers and doubles through `NSNumber` in ways that turn
/// `createdAt: 1774888596462` into a lossy double on re-serialization.
private struct JSONParser {
    let bytes: [UInt8]
    var offset = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D: offset += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard offset < bytes.count else { throw JSONValue.ParseError.malformed("unexpected end") }
        switch bytes[offset] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expect("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        let lit = [UInt8](literal.utf8)
        guard offset + lit.count <= bytes.count,
              Array(bytes[offset..<(offset + lit.count)]) == lit
        else { throw JSONValue.ParseError.malformed("expected \(literal)") }
        offset += lit.count
    }

    private mutating func parseObject() throws -> JSONValue {
        offset += 1  // {
        var object = JSONObject()
        skipWhitespace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
            offset += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
                throw JSONValue.ParseError.malformed("expected ':' after key \(key)")
            }
            offset += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard offset < bytes.count else { throw JSONValue.ParseError.malformed("unterminated object") }
            if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
            if bytes[offset] == UInt8(ascii: "}") { offset += 1; return .object(object) }
            throw JSONValue.ParseError.malformed("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        offset += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
            offset += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard offset < bytes.count else { throw JSONValue.ParseError.malformed("unterminated array") }
            if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
            if bytes[offset] == UInt8(ascii: "]") { offset += 1; return .array(items) }
            throw JSONValue.ParseError.malformed("expected ',' or ']'")
        }
    }

    /// Decodes a JSON string.
    ///
    /// The overwhelmingly common case is a run of bytes with no escape in it, so that case
    /// is decoded in one pass over the range rather than character by character. The
    /// earlier version allocated an `Array` and a `String` per character, which made a
    /// 10 MB transcript take 48 seconds; this makes the same file take well under a second.
    private mutating func parseString() throws -> String {
        guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
            throw JSONValue.ParseError.malformed("expected string")
        }
        offset += 1
        let start = offset

        // Fast scan: if the string holds no escape, the bytes are already valid UTF-8 and
        // can be handed to String wholesale.
        var index = offset
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\"") {
                offset = index + 1
                return String(decoding: bytes[start..<index], as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") { break }
            index += 1
        }
        guard index < bytes.count else { throw JSONValue.ParseError.malformed("unterminated string") }

        // Escaped path: accumulate raw UTF-8 and decode once at the end.
        var out = [UInt8]()
        out.reserveCapacity((bytes.count - start) / 4)
        out.append(contentsOf: bytes[start..<index])
        offset = index
        var pendingHighSurrogate: UInt32?

        func appendScalar(_ value: UInt32) {
            guard let scalar = Unicode.Scalar(value) else {
                out.append(contentsOf: [0xEF, 0xBF, 0xBD])
                return
            }
            UTF8.encode(scalar) { out.append($0) }
        }
        func flushLoneSurrogate() {
            if pendingHighSurrogate != nil {
                out.append(contentsOf: [0xEF, 0xBF, 0xBD])
                pendingHighSurrogate = nil
            }
        }

        while offset < bytes.count {
            let b = bytes[offset]
            if b == UInt8(ascii: "\"") {
                offset += 1
                flushLoneSurrogate()
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                offset += 1
                guard offset < bytes.count else { break }
                let escape = bytes[offset]
                offset += 1
                if escape == UInt8(ascii: "u") {
                    let code = try parseHex4()
                    if code >= 0xD800, code <= 0xDBFF {
                        flushLoneSurrogate()
                        pendingHighSurrogate = code
                    } else if code >= 0xDC00, code <= 0xDFFF, let high = pendingHighSurrogate {
                        appendScalar(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00))
                        pendingHighSurrogate = nil
                    } else {
                        flushLoneSurrogate()
                        appendScalar(code)
                    }
                    continue
                }
                flushLoneSurrogate()
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                default: throw JSONValue.ParseError.malformed("bad escape")
                }
                continue
            }
            flushLoneSurrogate()
            // Copy the whole run up to the next quote or backslash in one go.
            var run = offset
            while run < bytes.count,
                  bytes[run] != UInt8(ascii: "\""), bytes[run] != UInt8(ascii: "\\") {
                run += 1
            }
            out.append(contentsOf: bytes[offset..<run])
            offset = run
        }
        throw JSONValue.ParseError.malformed("unterminated string")
    }

    private static func utf8SequenceLength(_ b: UInt8) -> Int {
        if b < 0x80 { return 1 }
        if b & 0xE0 == 0xC0 { return 2 }
        if b & 0xF0 == 0xE0 { return 3 }
        if b & 0xF8 == 0xF0 { return 4 }
        return 1
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw JSONValue.ParseError.malformed("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[offset]
            offset += 1
            let digit: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A")) + 10
            default: throw JSONValue.ParseError.malformed("bad hex digit")
            }
            value = value << 4 | digit
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = offset
        var isDouble = false
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "-") { offset += 1 }
        while offset < bytes.count {
            let c = bytes[offset]
            if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
                offset += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
                        || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                isDouble = true
                offset += 1
            } else {
                break
            }
        }
        guard start < offset,
              let text = String(bytes: bytes[start..<offset], encoding: .utf8)
        else { throw JSONValue.ParseError.malformed("bad number") }

        if !isDouble, let i = Int64(text) { return .int(i) }
        guard let d = Double(text) else { throw JSONValue.ParseError.malformed("bad number \(text)") }
        return .double(d)
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Compact serialization preserving object key order. This is what gets written back
    /// to disk: Claude Desktop and Claude Code both `JSON.parse` these files, so
    /// whitespace is irrelevant to them, but stable key order keeps diffs reviewable.
    public func serialized() -> Data {
        var out = Data()
        out.reserveCapacity(1024)
        write(into: &out, sortKeys: false)
        return out
    }

    /// Key-sorted serialization, used only for content fingerprinting in round-trip tests.
    public func serializedCanonical() -> Data {
        var out = Data()
        write(into: &out, sortKeys: true)
        return out
    }

    private func write(into out: inout Data, sortKeys: Bool) {
        switch self {
        case .null:
            out.append(contentsOf: [UInt8](("null").utf8))
        case .bool(let b):
            out.append(contentsOf: [UInt8]((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: [UInt8](String(i).utf8))
        case .double(let d):
            out.append(contentsOf: [UInt8](Self.encodeDouble(d).utf8))
        case .string(let s):
            Self.writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                item.write(into: &out, sortKeys: sortKeys)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            let pairs = sortKeys ? o.orderedPairs.sorted { $0.key < $1.key } : o.orderedPairs
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(pair.key, into: &out)
                out.append(UInt8(ascii: ":"))
                pair.value.write(into: &out, sortKeys: sortKeys)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func encodeDouble(_ d: Double) -> String {
        // JSON has no representation for these; the source files never contain them, but a
        // corrupted record should not produce invalid JSON on write.
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    private static func writeString(_ s: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: [UInt8]("\\\"".utf8))
            case "\\": out.append(contentsOf: [UInt8]("\\\\".utf8))
            case "\n": out.append(contentsOf: [UInt8]("\\n".utf8))
            case "\r": out.append(contentsOf: [UInt8]("\\r".utf8))
            case "\t": out.append(contentsOf: [UInt8]("\\t".utf8))
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: [UInt8](String(format: "\\u%04x", scalar.value).utf8))
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
