import Foundation

/// The shape of what one version of a tool writes: each kind of record, the fields it has and
/// their JSON types, and the values of the few fields that name a kind of thing (a record's
/// type, a model). Never content: no text, paths, ids, times or numbers.
///
/// Shapes are how Better Claude notices that Claude Code changed its files. The ones in the
/// test corpus come from real transcripts, one per version, and every change to what Better
/// Claude reads is checked against all of them.
public struct FormatShape: Codable, Equatable, Sendable {
    public var format: String
    public var version: String
    /// By record kind: `assistant`, `system/away_summary`, `attachment/hook_success`.
    public var kinds: [String: Kind]

    public struct Kind: Codable, Equatable, Sendable {
        /// Dotted paths, `[]` for an array's elements and `*` for a map's entries, to the JSON
        /// types seen there.
        public var fields: [String: [String]] = [:]
        public var values: [String: [String]] = [:]

        public init() {}

        // One line per field in the corpus files: `"message.usage": "object"`, `"x": "null string"`.
        enum CodingKeys: String, CodingKey { case fields, values }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fields = try container.decode([String: String].self, forKey: .fields)
                .mapValues { $0.split(separator: " ").map(String.init) }
            values = try container.decodeIfPresent([String: [String]].self, forKey: .values) ?? [:]
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fields.mapValues { $0.joined(separator: " ") }, forKey: .fields)
            if !values.isEmpty { try container.encode(values, forKey: .values) }
        }

        mutating func insert(field: String, type: String) {
            if fields[field]?.contains(type) == true { return }
            fields[field, default: []].append(type)
            fields[field]?.sort()
        }

        mutating func insert(value: String, at path: String) {
            if values[path]?.contains(value) == true { return }
            values[path, default: []].append(value)
            values[path]?.sort()
        }

        mutating func merge(_ other: Kind) {
            for (field, types) in other.fields { for type in types { insert(field: field, type: type) } }
            for (path, values) in other.values { for value in values { insert(value: value, at: path) } }
        }
    }

    public init(format: String, version: String, kinds: [String: Kind] = [:]) {
        self.format = format
        self.version = version
        self.kinds = kinds
    }

    public mutating func merge(_ other: FormatShape) {
        for (name, kind) in other.kinds { kinds[name, default: Kind()].merge(kind) }
    }

    /// Stable, readable JSON, so a corpus diff shows exactly what changed.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func decode(_ data: Data) throws -> FormatShape {
        try JSONDecoder().decode(FormatShape.self, from: data)
    }

    /// Whether `key` can be written into a shape: a field name, not something from the content
    /// (a path, an id, an address).
    public static func isFieldName(_ key: String) -> Bool {
        guard (1...48).contains(key.utf8.count), let first = key.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first), key.unicodeScalars.allSatisfy({
                  $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0))
              }) else { return false }
        // Ids aren't names: a long run of hex, or a word mixing digits and letters the way
        // generated ids do (`toolu_01NWcyHL…`, `msg_0142…`).
        if key.count >= 16 && key.allSatisfy(\.isHexDigit) { return false }
        return !key.split(separator: "_").contains { part in
            let digits = part.filter(\.isNumber).count
            return (part.count >= 10 && digits >= 2) || (digits >= 4 && digits * 2 >= part.count)
        }
    }

    /// Whether `value` can be written into a shape as a named thing: short, one word, no
    /// separators a path or a sentence would have.
    public static func isNameValue(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.<>[]")
        return value.unicodeScalars.allSatisfy(allowed.contains) && !value.contains("..")
    }
}

/// What Better Claude needs from one tool's files, and how to take their shape.
public struct FormatContract: Sendable {

    /// A field Better Claude reads.
    public struct Requirement: Sendable, Equatable {
        public let kinds: [String]
        public let path: String
        /// JSON types it can be; a field seen only as something else has changed meaning.
        public let types: Set<String>
        /// What stops working without it, in words for a person.
        public let feature: String
        /// Fields that are only there sometimes: missing from a whole version isn't a change.
        public var optional = false
    }

    /// Something a shape shows that Better Claude's reading doesn't account for.
    public enum Finding: Sendable, Equatable, CustomStringConvertible {
        /// A field it reads is gone from a kind of record that's still written.
        case missing(kind: String, path: String, feature: String)
        /// A field it reads now holds a different type of value.
        case changedType(kind: String, path: String, seen: [String], feature: String)
        /// A kind of record nobody has looked at yet: new data it may be missing.
        case unknownKind(String)
        /// A model the price table doesn't know, so its usage is weighed at a guess.
        case unpricedModel(String)

        /// Whether it means something Better Claude shows is now wrong or missing.
        public var breaksSomething: Bool {
            switch self {
            case .missing, .changedType: return true
            case .unknownKind, .unpricedModel: return false
            }
        }

        public var description: String {
            switch self {
            case .missing(let kind, let path, let feature):
                return "\(kind) records no longer have \(path): \(feature)"
            case .changedType(let kind, let path, let seen, let feature):
                return "\(kind) records have \(path) as \(seen.joined(separator: " or ")): \(feature)"
            case .unknownKind(let kind):
                return "a new kind of record, \(kind)"
            case .unpricedModel(let model):
                return "a model without a known price, \(model)"
            }
        }
    }

    public let format: String
    /// The tool, as a person would name it.
    public let name: String
    let kindOf: @Sendable (JSONValue) -> String?
    /// The version a record says wrote it, when it says.
    let versionOf: @Sendable (JSONValue) -> String?
    /// Paths whose string values name a kind of thing and are kept.
    let valuePaths: Set<String>
    /// Paths recorded as a type only; what's inside can come from anywhere. `a.*` means each
    /// of `a`'s fields is.
    let opaque: Set<String>
    /// Paths whose entries are keyed by content (a file path, a server name).
    let maps: Set<String>
    /// Objects where only these fields are recorded: which fields a tool takes says which
    /// tools someone has, so a tool's input keeps only what Better Claude reads.
    let onlyFields: [String: Set<String>]
    /// Arrays of blocks named by their `type`, recorded per type.
    let typedArrays: Set<String>
    let maxDepth: Int
    public let requirements: [Requirement]
    /// Every kind of record someone has looked at: read by Better Claude, or not needed.
    public let known: Set<String>
    /// The path holding the model, whose values are checked against the price table.
    let modelPath: String?

    /// Every finding for one version's shape.
    public func check(_ shape: FormatShape) -> [Finding] {
        var findings: [Finding] = []
        for requirement in requirements {
            for kind in requirement.kinds {
                guard let seen = shape.kinds[kind] else { continue }
                if let types = seen.fields[requirement.path] {
                    if requirement.types.isDisjoint(with: types) {
                        findings.append(.changedType(kind: kind, path: requirement.path, seen: types,
                                                     feature: requirement.feature))
                    }
                } else if !requirement.optional, Self.parentSeen(requirement.path, in: seen) {
                    findings.append(.missing(kind: kind, path: requirement.path, feature: requirement.feature))
                }
            }
        }
        for kind in shape.kinds.keys.sorted() where !known.contains(kind) {
            findings.append(.unknownKind(kind))
        }
        if let modelPath {
            let models = Set(shape.kinds.values.flatMap { $0.values[modelPath] ?? [] })
            for model in models.sorted() where !model.hasPrefix("<") && !Pricing.knows(model) {
                findings.append(.unpricedModel(model))
            }
        }
        return findings
    }

    /// A field can only be missing where the thing holding it was seen: a snapshot that
    /// tracked no files has no entries to lack a version.
    static func parentSeen(_ path: String, in kind: FormatShape.Kind) -> Bool {
        guard let cut = path.lastIndex(of: ".") else { return true }
        return kind.fields[String(path[..<cut])]?.contains("object") == true
    }

    // MARK: Taking a shape

    /// Adds one record to `shape`.
    public func absorb(_ record: JSONValue, into shape: inout FormatShape) {
        guard let kind = kindOf(record) else { return }
        var entry = shape.kinds[kind] ?? FormatShape.Kind()
        walk(record, path: "", depth: 0, into: &entry)
        shape.kinds[kind] = entry
    }

    private func walk(_ value: JSONValue, path: String, depth: Int, into kind: inout FormatShape.Kind) {
        if !path.isEmpty { kind.insert(field: path, type: Self.typeName(value)) }
        if valuePaths.contains(path), let string = value.stringValue, FormatShape.isNameValue(string) {
            kind.insert(value: string, at: path)
        }
        guard !isOpaque(path), depth < maxDepth else { return }
        switch value {
        case .object(let object):
            let isMap = maps.contains(path)
            let only = onlyFields[path]
            for (key, child) in object.orderedPairs where only?.contains(key) ?? true {
                let name = isMap || !FormatShape.isFieldName(key) ? "*" : key
                walk(child, path: path.isEmpty ? name : "\(path).\(name)", depth: depth + 1, into: &kind)
            }
        case .array(let elements):
            let typed = typedArrays.contains(path)
            for element in elements.prefix(64) {
                // `content[tool_use]`: blocks of different types have different fields.
                let type = typed ? element["type"]?.stringValue.flatMap { FormatShape.isNameValue($0) ? $0 : nil } : nil
                walk(element, path: path + "[\(type ?? "")]", depth: depth + 1, into: &kind)
            }
        default:
            break
        }
    }

    func isOpaque(_ path: String) -> Bool {
        if opaque.contains(path) { return true }
        guard let cut = path.lastIndex(of: ".") else { return false }
        return opaque.contains(path[..<cut] + ".*")
    }

    static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
