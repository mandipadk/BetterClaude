import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Unattended")
struct UnattendedTests {
    @Test("Background jobs are read with how each ended, and one silent for hours is stalled; loops are found")
    func jobsAndLoops() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            let jobs = Unattended.jobs(configDirs: [sample.paths.claudeCodeConfigDir], now: sample.now)
            #expect(jobs.count == 3)
            let audit = try #require(jobs.first { $0.name == "Nightly dependency audit" })
            #expect(audit.outcome == .finished && audit.result?.hasPrefix("No vulnerable versions") == true)
            #expect(jobs.first { $0.name == "Refresh the fixtures" }?.outcome == .failed)
            let stuck = try #require(jobs.first { $0.name == "Translate settings strings" })
            #expect(stuck.outcome == .stalled && stuck.lastUpdate == "Translating 42 strings into German")

            try await index.update(from: snapshot)
            let loops = try await Unattended.loops(index: index, since: sample.now.addingTimeInterval(-7 * 86_400))
            #expect(loops.first?.title == "Add a health check endpoint" && loops.first?.wakeups == 6)
        }
    }
}
