import Foundation

/// What changed between two versions of a text file, as lines with a few of context around
/// each change, the way a unified diff reads.
public struct LineDiff: Sendable, Equatable {

    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case context, added, removed, gap }
        public let id: Int
        public let kind: Kind
        public let text: String
        /// The line's number in the old version, or the new one for an added line.
        public let number: Int?
    }

    public let lines: [Line]
    public let added: Int
    public let removed: Int

    public var isEmpty: Bool { added == 0 && removed == 0 }

    public init(old: String, new: String, context: Int = 3) {
        let before = Self.lines(old)
        let after = Self.lines(new)
        let difference = after.difference(from: before)

        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        // Walk both versions together: unchanged lines advance both, removals only the old,
        // insertions only the new.
        var rows: [(Line.Kind, String, Int?)] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removedAt.contains(i) {
                rows.append((.removed, before[i], i + 1)); i += 1
            } else if j < after.count, insertedAt.contains(j) {
                rows.append((.added, after[j], j + 1)); j += 1
            } else {
                if i < before.count { rows.append((.context, before[i], i + 1)) }
                i += 1; j += 1
            }
        }

        // Keep only changes and the context around them; mark what's skipped.
        let changed = rows.indices.filter { rows[$0].0 != .context }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(rows.count - 1, index + context) { keep.insert(k) }
        }
        var out: [Line] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 {
                out.append(Line(id: out.count, kind: .gap, text: "", number: nil))
            }
            let row = rows[index]
            out.append(Line(id: out.count, kind: row.0, text: row.1, number: row.2))
            previous = index
        }
        lines = out
        added = rows.filter { $0.0 == .added }.count
        removed = rows.filter { $0.0 == .removed }.count
    }

    /// A text's lines, without the empty one after its final line break; nothing at all
    /// for an empty text.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
