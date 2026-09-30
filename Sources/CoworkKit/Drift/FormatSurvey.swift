import Foundation

/// Taking the shape of real files, by the version that wrote them.
public enum FormatSurvey {

    /// Shapes by version, from `urls`. A record that doesn't say which version wrote it counts
    /// for the version the file's records say around it.
    public static func shapes(of urls: [URL], contract: FormatContract, byteLimit: Int = .max) -> [String: FormatShape] {
        var shapes: [String: FormatShape] = [:]
        var bytes = 0
        for url in urls {
            guard bytes < byteLimit, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            bytes += data.count
            var current: String?
            var waiting: [JSONValue] = []
            for line in data.split(separator: 0x0A) {
                guard let record = try? JSONValue.parse(Data(line)) else { continue }
                if let version = contract.versionOf(record) {
                    current = version
                    for earlier in waiting { contract.absorb(earlier, into: &shapes[version, default: .init(format: contract.format, version: version)]) }
                    waiting = []
                }
                if let current {
                    contract.absorb(record, into: &shapes[current, default: .init(format: contract.format, version: current)])
                } else {
                    waiting.append(record)
                }
            }
        }
        return shapes
    }

    /// Versions oldest first, by their numbers: 2.1.9 before 2.1.10.
    public static func ordered(_ versions: some Sequence<String>) -> [String] {
        versions.sorted { a, b in
            let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return x.lexicographicallyPrecedes(y) || (x == y && a < b)
        }
    }

    /// The newest version's shape of each tool on this Mac, and what it shows.
    public struct Report: Sendable {
        public let contract: FormatContract
        public let shape: FormatShape
        public let findings: [FormatContract.Finding]
        /// The findings that mean something Better Claude shows is wrong or missing.
        public var breaking: [FormatContract.Finding] { findings.filter(\.breaksSomething) }

        public init(contract: FormatContract, shape: FormatShape) {
            self.contract = contract
            self.shape = shape
            findings = contract.check(shape)
        }
    }

    /// Checks the newest version of Claude Code and Codex seen in the most recent
    /// conversations. Reads at most `byteLimit` of each, newest first.
    public static func check(_ conversations: [ConversationRef], recent: Int = 12, byteLimit: Int = 256 << 20) -> [Report] {
        let sorted = conversations.sorted { $0.lastActivity > $1.lastActivity }
        var claudeCode: [URL] = []
        var codex: [URL] = []
        for conversation in sorted {
            if let external = conversation.external {
                if external.source == .codex, codex.count < recent { codex.append(external.fileURL) }
            } else if let url = conversation.transcriptURL, claudeCode.count < recent {
                claudeCode.append(url)
            }
        }
        return [(FormatContract.claudeCode, claudeCode), (FormatContract.codex, codex)].compactMap { contract, urls in
            let shapes = shapes(of: urls, contract: contract, byteLimit: byteLimit)
            guard let newest = ordered(shapes.keys).last, let shape = shapes[newest] else { return nil }
            return Report(contract: contract, shape: shape)
        }
    }
}

extension FormatContract.Finding {
    /// What a person loses, for the ones that break something.
    public var feature: String? {
        switch self {
        case .missing(_, _, let feature), .changedType(_, _, _, let feature): return feature
        case .unknownKind, .unpricedModel: return nil
        }
    }
}
