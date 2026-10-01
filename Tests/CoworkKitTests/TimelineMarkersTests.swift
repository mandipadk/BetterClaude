import Foundation
import Testing
@testable import CoworkKit

@Suite("Timeline markers")
struct TimelineMarkersTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func marker(_ id: String, _ minutes: Double) -> TimelineMarker {
        TimelineMarker(id: id, at: start.addingTimeInterval(minutes * 60), kind: .cacheBreak(gap: 1_800, cost: 0.3))
    }

    @Test("A marker goes before the first message at or after it, and after every message at the end")
    func anchors() {
        let times: [Date?] = [start, start.addingTimeInterval(60), nil, start.addingTimeInterval(600)]
        let anchors = TimelineMarkers.anchors([marker("a", 0.5), marker("b", 5), marker("c", 20)], times: times)
        #expect(anchors[1]?.map(\.id) == ["a"])
        // The entry without a time takes the one before it, so "b" still lands before the last.
        #expect(anchors[3]?.map(\.id) == ["b"])
        #expect(anchors[4]?.map(\.id) == ["c"])
    }

    @Test("Markers at the very start go before the first message")
    func first() {
        let anchors = TimelineMarkers.anchors([marker("a", -1)], times: [start])
        #expect(anchors[0]?.map(\.id) == ["a"])
    }
}
