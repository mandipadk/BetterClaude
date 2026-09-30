import Foundation

/// Work Claude Code does while nobody watches: background jobs (`claude --bg`, `/fork`), and
/// sessions that keep themselves going with /loop. What each is doing, how it ended, and the
/// ones that stopped without saying.
public enum Unattended {

    public struct Job: Sendable, Identifiable, Equatable {
        public enum Outcome: String, Sendable {
            case running, finished, failed
            /// Its record says it's working, but it hasn't moved in a long while and nothing is
            /// running it: it stopped without finishing.
            case stalled
        }
        public let id: String
        public let name: String
        public let cwd: String?
        public let sessionID: String?
        public let state: String
        public let outcome: Outcome
        public let started: Date?
        public let updated: Date?
        public let tokens: Int
        /// What it came back with, when it finished with something to say.
        public let result: String?
        /// The last thing it reported while working.
        public let lastUpdate: String?
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSince1970: number > 1e11 ? number / 1_000 : number) }
        if let text = value as? String { return Transcript.parseTimestamp(text) ?? ISO8601DateFormatter().date(from: text) }
        return nil
    }

    /// Background jobs in each Claude Code config folder, newest first. Their environment
    /// (`providerEnv`, which can hold keys) is never read out.
    public static func jobs(configDirs: [URL], now: Date = Date(), stalledAfter: TimeInterval = 30 * 60) -> [Job] {
        var jobs: [Job] = []
        for config in configDirs {
            let root = config.appendingPathComponent("jobs", isDirectory: true)
            for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let folder = root.appendingPathComponent(id, isDirectory: true)
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let raw = (state["state"] as? String) ?? "unknown"
                let updated = date(state["updatedAt"]) ?? date(state["lastTerminalAt"])
                let result = ((state["output"] as? [String: Any])?["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                var lastUpdate: String?
                if let timeline = try? String(contentsOf: folder.appendingPathComponent("timeline.jsonl"), encoding: .utf8) {
                    for line in timeline.split(separator: "\n").reversed() {
                        if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                           let text = (entry["text"] as? String) ?? (entry["detail"] as? String), !text.isEmpty {
                            lastUpdate = text
                            break
                        }
                    }
                }
                let outcome: Job.Outcome
                switch raw {
                case "done", "completed", "finished": outcome = .finished
                case "failed", "error", "errored", "killed", "crashed": outcome = .failed
                default:
                    let quiet = updated.map { now.timeIntervalSince($0) > stalledAfter } ?? true
                    outcome = quiet ? .stalled : .running
                }
                jobs.append(Job(id: id, name: (state["name"] as? String) ?? "Background job", cwd: state["cwd"] as? String,
                                sessionID: state["sessionId"] as? String, state: raw, outcome: outcome,
                                started: date(state["createdAt"]), updated: updated,
                                tokens: (state["tokens"] as? Int) ?? 0, result: result?.isEmpty == false ? result : nil,
                                lastUpdate: lastUpdate))
            }
        }
        return jobs.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// A conversation that kept itself going with /loop or scheduled wake-ups.
    public struct Loop: Sendable, Identifiable, Equatable {
        public var id: String { conversationID }
        public let conversationID: String
        public let title: String
        public let wakeups: Int
        public let first: Date?
        public let last: Date?
    }

    public static func loops(index: HistoryIndex, since: Date) async throws -> [Loop] {
        try await index.rows("""
            SELECT t.conversation_id, c.title, COUNT(*), MIN(t.timestamp), MAX(t.timestamp)
            FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
            WHERE t.name IN ('ScheduleWakeup', 'CronCreate') AND t.agent_id IS NULL AND t.timestamp >= ?
            GROUP BY t.conversation_id ORDER BY MAX(t.timestamp) DESC
            """, [.date(since)]).compactMap { row in
            guard let id = row.text(0) else { return nil }
            return Loop(conversationID: id, title: row.text(1) ?? "Untitled", wakeups: Int(row.int(2)),
                        first: row.date(3), last: row.date(4))
        }
    }
}
