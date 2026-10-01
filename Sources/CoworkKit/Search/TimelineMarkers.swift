import Foundation

/// Something that happened during a conversation that the reader shows where it happened,
/// as one quiet line between messages: sub-agents set off, the model changed, a reply came
/// back after the prompt cache had expired.
public struct TimelineMarker: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Top-level sub-agents that set off together.
        case subagents(count: Int, descriptions: [String], cost: Double)
        case modelSwitch(ModelDrift.Switch)
        /// A reply after a break long enough for the cache to expire.
        case cacheBreak(gap: TimeInterval, cost: Double)
    }

    public let id: String
    public let at: Date
    public let kind: Kind

    public init(id: String, at: Date, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

public enum TimelineMarkers {

    /// Sub-agents that set off within this long of each other are one burst.
    static let burstWindow: TimeInterval = 120

    /// Every marker for a conversation, earliest first.
    public static func markers(record: FlightRecord?, switches: [ModelDrift.Switch],
                               runs: [Subagents.Run]) -> [TimelineMarker] {
        var markers: [TimelineMarker] = []
        let topLevel = runs.filter { $0.depth <= 1 && $0.started != nil }.sorted { $0.started! < $1.started! }
        var burst: [Subagents.Run] = []
        func flush() {
            guard let first = burst.first, let at = first.started else { return }
            markers.append(TimelineMarker(id: "agents.\(first.agentID)", at: at,
                                          kind: .subagents(count: burst.count,
                                                           descriptions: burst.compactMap(\.description),
                                                           cost: burst.reduce(0) { $0 + $1.cost })))
            burst = []
        }
        for run in topLevel {
            if let last = burst.last?.started, run.started!.timeIntervalSince(last) > burstWindow { flush() }
            burst.append(run)
        }
        flush()
        for change in switches {
            markers.append(TimelineMarker(id: "switch.\(change.id)", at: change.at, kind: .modelSwitch(change)))
        }
        for reply in record?.replies ?? [] {
            guard let gap = reply.afterBreak else { continue }
            markers.append(TimelineMarker(id: "break.\(reply.id)", at: reply.timestamp,
                                          kind: .cacheBreak(gap: gap, cost: reply.cost)))
        }
        return markers.sorted { $0.at < $1.at }
    }

    /// Where each marker goes: before the first entry at or after its time. Entries without a
    /// time take the time of the one before them. Markers after every entry go at the end,
    /// under the key `times.count`.
    public static func anchors(_ markers: [TimelineMarker], times: [Date?]) -> [Int: [TimelineMarker]] {
        var filled: [Date?] = []
        var last: Date?
        for time in times {
            last = time ?? last
            filled.append(last)
        }
        var anchors: [Int: [TimelineMarker]] = [:]
        for marker in markers {
            let index = filled.firstIndex { ($0 ?? .distantPast) >= marker.at } ?? times.count
            anchors[index, default: []].append(marker)
        }
        return anchors
    }
}
