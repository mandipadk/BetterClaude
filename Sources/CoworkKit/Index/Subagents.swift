import Foundation

/// The sub-agents a Claude Code conversation spawned: each has a transcript of its own in
/// `<session>/subagents/agent-<id>.jsonl`, and newer ones a `.meta.json` saying what kind of
/// agent it was, what it was asked to do, and which call started it.
public enum Subagents {

    public struct Meta: Sendable, Decodable, Equatable {
        public let agentType: String?
        public let description: String?
        public let toolUseID: String?
        public let parentAgentID: String?
        public let depth: Int?
        /// The model it was asked to run on: "opus", "sonnet", "inherit", or an id.
        public let model: String?

        enum CodingKeys: String, CodingKey {
            case agentType, description, model
            case toolUseID = "toolUseId"
            case parentAgentID = "parentAgentId"
            case depth = "spawnDepth"
        }
    }

    public struct File: Sendable {
        public let url: URL
        public let agentID: String
        public let meta: Meta?
    }

    /// A conversation's sub-agent transcripts, if it has any.
    public static func files(beside transcript: URL) -> [File] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }.sorted().map { name in
            let agentID = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let meta = (try? Data(contentsOf: folder.appendingPathComponent("agent-\(agentID).meta.json")))
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            return File(url: folder.appendingPathComponent(name), agentID: agentID, meta: meta)
        }
    }

    /// One sub-agent's run, as the index keeps it.
    public struct Run: Sendable, Identifiable, Equatable {
        public var id: String { agentID }
        public let agentID: String
        /// "general-purpose", "Explore"; nil for older runs that didn't say.
        public let type: String?
        /// The short task it was given.
        public let description: String?
        public let parentAgentID: String?
        public let depth: Int
        public let model: String?
        /// The model it was asked for, when it was asked for one.
        public let requestedModel: String?
        public let started: Date?
        public let ended: Date?
        public let replies: Int
        public let tools: Int
        public let prompt: String?
        public let result: String?
        public let cost: Double
        public let tokens: Int64

        /// Asked for one model family and ran on another.
        public var ranOnOtherModel: Bool {
            guard let requested = requestedModel?.lowercased(), requested != "inherit", let model = model?.lowercased() else { return false }
            return !model.contains(requested.replacingOccurrences(of: "claude-", with: ""))
        }

        public var title: String {
            if let description, !description.isEmpty { return description }
            let line = prompt?.split(separator: "\n").first.map(String.init) ?? "A sub-agent"
            return line.count > 90 ? String(line.prefix(90)) + "…" : line
        }
    }

    /// A conversation's sub-agents in the order they started, each followed by the ones it
    /// spawned.
    public static func runs(conversationID: String, index: HistoryIndex) async throws -> [Run] {
        var costs: [String: (Double, Int64)] = [:]
        for row in try await index.rows("""
            SELECT agent_id, model, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write_5m), SUM(cache_write_1h)
            FROM usage WHERE conversation_id = ? AND agent_id IS NOT NULL GROUP BY agent_id, model
            """, [.text(conversationID)]) {
            guard let agent = row.text(0), let model = row.text(1) else { continue }
            let cost = Pricing.cost(model: model, input: row.int(2), output: row.int(3), cacheRead: row.int(4),
                                    cacheWrite5m: row.int(5), cacheWrite1h: row.int(6))
            let tokens = row.int(2) + row.int(3) + row.int(4) + row.int(5) + row.int(6)
            costs[agent] = ((costs[agent]?.0 ?? 0) + cost, (costs[agent]?.1 ?? 0) + tokens)
        }
        let runs = try await index.rows("""
            SELECT agent_id, agent_type, description, parent_agent_id, depth, model, first_activity, last_activity,
                   replies, tools, prompt, result, requested_model
            FROM subagents WHERE conversation_id = ? ORDER BY first_activity
            """, [.text(conversationID)]).compactMap { row -> Run? in
            guard let agent = row.text(0) else { return nil }
            return Run(agentID: agent, type: row.text(1), description: row.text(2), parentAgentID: row.text(3),
                       depth: Int(row.intOrNil(4) ?? 1), model: row.text(5), requestedModel: row.text(12),
                       started: row.date(6), ended: row.date(7),
                       replies: Int(row.int(8)), tools: Int(row.int(9)), prompt: row.text(10), result: row.text(11),
                       cost: costs[agent]?.0 ?? 0, tokens: costs[agent]?.1 ?? 0)
        }
        // Children right after their parent.
        let children = Dictionary(grouping: runs.filter { $0.parentAgentID != nil }, by: { $0.parentAgentID! })
        var ordered: [Run] = []
        func add(_ run: Run) {
            ordered.append(run)
            for child in children[run.agentID] ?? [] { add(child) }
        }
        for run in runs where run.parentAgentID == nil || !runs.contains(where: { $0.agentID == run.parentAgentID }) { add(run) }
        return ordered
    }
}
