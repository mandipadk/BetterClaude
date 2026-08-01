import Foundation

/// Two scopes lined up against each other, one row per configuration item.
public struct ConfigComparison: Sendable {

    public struct Row: Sendable, Identifiable, Hashable {
        public let id: String
        public let kind: ConfigKind
        public let name: String
        public let left: ConfigItem?
        public let right: ConfigItem?
        public var status: Status

        public init(id: String, kind: ConfigKind, name: String,
                    left: ConfigItem?, right: ConfigItem?, status: Status) {
            self.id = id
            self.kind = kind
            self.name = name
            self.left = left
            self.right = right
            self.status = status
        }
    }

    public enum Status: String, Sendable {
        case onlyLeft, onlyRight, same, different
    }

    public let left: ConfigScope, right: ConfigScope
    public let rows: [Row]

    public init(left: ConfigScope, right: ConfigScope, rows: [Row]) {
        self.left = left
        self.right = right
        self.rows = rows
    }

    public var summary: (onlyLeft: Int, onlyRight: Int, same: Int, different: Int) {
        var counts: (onlyLeft: Int, onlyRight: Int, same: Int, different: Int) = (0, 0, 0, 0)
        for row in rows {
            switch row.status {
            case .onlyLeft: counts.onlyLeft += 1
            case .onlyRight: counts.onlyRight += 1
            case .same: counts.same += 1
            case .different: counts.different += 1
            }
        }
        return counts
    }

    public func rows(ofKind kind: ConfigKind) -> [Row] {
        rows.filter { $0.kind == kind }
    }
}

public enum ConfigDiff {

    /// Match items across two scopes by `(kind, name)`.
    ///
    /// Name is the right key rather than path or hash: the whole point of the comparison is
    /// that `code-review` in one install and `code-review` in another are the same idea living
    /// at different paths, and a hash-keyed match would report every edited copy as two
    /// unrelated items instead of one difference.
    public static func compare(_ left: ConfigScope, _ right: ConfigScope) throws -> ConfigComparison {
        let leftItems = (try? ConfigInventory.items(in: left)) ?? []
        let rightItems = (try? ConfigInventory.items(in: right)) ?? []
        return compare(left, leftItems, right, rightItems)
    }

    /// The pure half, so a caller that already has both inventories does not read the disk
    /// twice — and so the matching can be tested without a store.
    public static func compare(_ left: ConfigScope, _ leftItems: [ConfigItem],
                               _ right: ConfigScope, _ rightItems: [ConfigItem])
        -> ConfigComparison {

        var leftByKey: [String: [ConfigItem]] = [:]
        for item in leftItems { leftByKey[item.matchKey, default: []].append(item) }
        var rightByKey: [String: [ConfigItem]] = [:]
        for item in rightItems { rightByKey[item.matchKey, default: []].append(item) }

        var rows: [ConfigComparison.Row] = []
        for key in Set(leftByKey.keys).union(rightByKey.keys) {
            let lefts = leftByKey[key] ?? []
            let rights = rightByKey[key] ?? []
            // One scope can legitimately hold two items with the same kind and name — a skill
            // installed both directly and by a plugin. Pairing them in order keeps the row
            // count honest instead of collapsing them into one arbitrary winner.
            for index in 0..<max(lefts.count, rights.count) {
                let leftItem = index < lefts.count ? lefts[index] : nil
                let rightItem = index < rights.count ? rights[index] : nil
                let sample = leftItem ?? rightItem
                guard let sample else { continue }
                rows.append(ConfigComparison.Row(
                    id: rights.count + lefts.count > 1 ? "\(key)#\(index)" : key,
                    kind: sample.kind, name: sample.name,
                    left: leftItem, right: rightItem,
                    status: status(leftItem, rightItem)))
            }
        }

        rows.sort {
            $0.kind.order == $1.kind.order
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.kind.order < $1.kind.order
        }
        return ConfigComparison(left: left, right: right, rows: rows)
    }

    /// Two items that both exist are `.different` when their fingerprints differ.
    ///
    /// A missing fingerprint — an unreadable directory, a JSON-derived item with nothing to
    /// hash — is treated as `.same` rather than `.different`, because the alternative is a
    /// comparison that flags rows it has no evidence about.
    static func status(_ left: ConfigItem?, _ right: ConfigItem?) -> ConfigComparison.Status {
        switch (left, right) {
        case (.some, .none): return .onlyLeft
        case (.none, .some): return .onlyRight
        case (.some(let l), .some(let r)):
            guard let lh = l.contentHash, let rh = r.contentHash else { return .same }
            return lh == rh ? .same : .different
        case (.none, .none): return .same
        }
    }
}
