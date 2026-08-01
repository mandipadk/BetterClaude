import Foundation

/// An ordered set of literal string substitutions applied in one left-to-right pass.
///
/// Session transfers have to rewrite absolute paths that are embedded in free text — tool
/// results, `cwd` fields, shell transcripts, error messages. Two failure modes are both
/// severe and they pull in opposite directions, so the semantics here are deliberately
/// narrow:
///
/// * **Prefix shadowing.** With rules `/a/b -> X` and `/a -> Y`, a naive map turns `/a/b/c`
///   into `Y/b/c`. Rules are therefore sorted by descending `from` length in ``init``, and
///   that order is observable through ``rules`` so callers can assert on it.
/// * **Cascading.** Applying rules one after another over the whole string lets rule 2
///   match text that rule 1 just produced, which silently double-rewrites a path when the
///   old and new roots overlap. ``apply(to:)`` instead makes a single scan and never
///   re-examines emitted output, so replacements are non-overlapping, one pass, and
///   idempotent whenever no `to` value is matched by some `from`.
public struct RewriteMap: Sendable {

    /// One substitution, after normalization and ordering.
    public struct Rule: Sendable, Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    private let ordered: [Rule]
    private let patterns: [[UInt8]]
    private let replacements: [[UInt8]]
    /// 256-entry lookup of "some rule could start here", so the scan skips whole runs of
    /// text — the transcripts this runs over are tens of megabytes.
    private let leadByte: [Bool]

    /// Rules with an empty `from`, and duplicates of an earlier `from`, are dropped: the
    /// first would match at every position and the second is unreachable. Ties in length
    /// keep the caller's relative order, which makes the result deterministic.
    public init(orderedRules: [(from: String, to: String)]) {
        var seen = Set<String>()
        var kept: [(index: Int, rule: Rule)] = []
        for (index, pair) in orderedRules.enumerated() {
            guard !pair.from.isEmpty, seen.insert(pair.from).inserted else { continue }
            kept.append((index, Rule(from: pair.from, to: pair.to)))
        }

        let sorted = kept.sorted { lhs, rhs in
            let l = lhs.rule.from.utf8.count
            let r = rhs.rule.from.utf8.count
            if l != r { return l > r }
            return lhs.index < rhs.index
        }

        ordered = sorted.map(\.rule)
        patterns = ordered.map { Array($0.from.utf8) }
        replacements = ordered.map { Array($0.to.utf8) }

        var lead = [Bool](repeating: false, count: 256)
        for pattern in patterns where !pattern.isEmpty { lead[Int(pattern[0])] = true }
        leadByte = lead
    }

    public init(rules: [Rule]) {
        self.init(orderedRules: rules.map { (from: $0.from, to: $0.to) })
    }

    /// Always longest-`from`-first.
    public var rules: [(from: String, to: String)] {
        ordered.map { (from: $0.from, to: $0.to) }
    }

    public var isEmpty: Bool { ordered.isEmpty }

    /// Rewrite `s`, returning the result and the number of substitutions made.
    ///
    /// Matching is done over UTF-8 bytes. That is safe rather than merely fast: UTF-8 is
    /// self-synchronizing, so a valid needle can neither begin nor end inside a multi-byte
    /// sequence of the haystack, and a byte match is always a character match.
    public func apply(to s: String) -> (String, Int) {
        guard !ordered.isEmpty, !s.isEmpty else { return (s, 0) }

        let src = Array(s.utf8)
        var out: [UInt8]?
        var count = 0
        var i = 0

        while i < src.count {
            let byte = src[i]
            if leadByte[Int(byte)] {
                var hit = -1
                for k in patterns.indices {
                    let pattern = patterns[k]
                    if i + pattern.count <= src.count, Self.matches(src, at: i, pattern) {
                        hit = k
                        break
                    }
                }
                if hit >= 0 {
                    if out == nil {
                        var buffer = [UInt8]()
                        buffer.reserveCapacity(src.count + 32)
                        buffer.append(contentsOf: src[0..<i])
                        out = buffer
                    }
                    out!.append(contentsOf: replacements[hit])
                    i += patterns[hit].count
                    count += 1
                    continue
                }
            }
            if out != nil { out!.append(byte) }
            i += 1
        }

        guard let result = out else { return (s, 0) }
        return (String(decoding: result, as: UTF8.self), count)
    }

    @inline(__always)
    private static func matches(_ src: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        var j = 0
        while j < pattern.count {
            if src[index + j] != pattern[j] { return false }
            j += 1
        }
        return true
    }

    /// Non-overlapping occurrences of `needle` in `s`, using the same byte matching as
    /// ``apply(to:)`` so verification counts and rewrite counts are directly comparable.
    public static func occurrences(of needle: String, in s: String) -> Int {
        guard !needle.isEmpty, !s.isEmpty else { return 0 }
        let pattern = Array(needle.utf8)
        let src = Array(s.utf8)
        guard src.count >= pattern.count else { return 0 }

        var count = 0
        var i = 0
        let limit = src.count - pattern.count
        while i <= limit {
            if src[i] == pattern[0], matches(src, at: i, pattern) {
                count += 1
                i += pattern.count
            } else {
                i += 1
            }
        }
        return count
    }
}

// MARK: - Standard maps

extension RewriteMap {

    /// Rules for moving a Cowork session workspace from one absolute root to another.
    ///
    /// Covers the host workspace root, its `outputs/` and `uploads/` subdirectories, the
    /// in-VM `/sessions/<processName>` path that non-host-loop sessions use as `cwd`, and
    /// the ``PathEncoder``-encoded project-directory names for both, which appear verbatim
    /// in tool output whenever the agent has listed or read under `.claude/projects/`.
    ///
    /// `outputs` and `uploads` are listed before the bare root only for readability — the
    /// longest-first sort in ``init(orderedRules:)`` is what actually guarantees
    /// `<root>/outputs` wins over `<root>`. Identity rules are dropped so the replacement
    /// count reported by ``RewriteEngine`` reflects real changes.
    public static func forWorkspaceMove(oldWorkspaceRoot: String, newWorkspaceRoot: String,
                                        oldProcessName: String, newProcessName: String) -> RewriteMap {
        let oldRoot = trimmingTrailingSlashes(oldWorkspaceRoot)
        let newRoot = trimmingTrailingSlashes(newWorkspaceRoot)
        let oldVM = "/sessions/" + oldProcessName
        let newVM = "/sessions/" + newProcessName

        var candidates: [(from: String, to: String)] = [
            (oldRoot + "/outputs", newRoot + "/outputs"),
            (oldRoot + "/uploads", newRoot + "/uploads"),
            (oldRoot, newRoot),
            (oldVM, newVM),
            (PathEncoder.encode(oldRoot + "/outputs"), PathEncoder.encode(newRoot + "/outputs")),
            (PathEncoder.encode(oldRoot), PathEncoder.encode(newRoot)),
            (PathEncoder.encode(oldVM), PathEncoder.encode(newVM)),
        ]
        candidates.removeAll { $0.from == $0.to || $0.from.isEmpty }
        return RewriteMap(orderedRules: candidates)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
