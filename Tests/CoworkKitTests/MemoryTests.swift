import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Memory")
struct MemoryTests {

    @Test("Memory is found everywhere Claude keeps it, and memory for a deleted folder is flagged")
    func findsMemory() throws {
        try FixtureHomeTests.withSample { _ in
            let groups = MemoryInventory.groups(installs: InstallDiscovery.all())
            #expect(groups.contains { $0.kind == .everywhere && $0.files.map(\.name) == ["CLAUDE.md"] })

            let billing = try #require(groups.first { $0.title == "billing-service" })
            #expect(Set(billing.files.map(\.name)) == ["MEMORY.md", "retry-policy.md"])
            #expect(!billing.isOrphaned)

            let journal = try #require(groups.first { $0.title == "journal-app" })
            #expect(journal.files.map(\.name).contains("CLAUDE.md"))

            let prototype = try #require(groups.first { $0.title == "old-prototype" })
            #expect(prototype.isOrphaned)

            let planning = try #require(groups.first { $0.kind == .coworkProject })
            #expect(planning.title == "Q4 planning")
            #expect(!planning.isOrphaned)
        }
    }

    @Test("Search looks inside memory files")
    func searchesContents() throws {
        try FixtureHomeTests.withSample { _ in
            let groups = MemoryInventory.groups(installs: InstallDiscovery.all())
            let found = MemoryInventory.search(groups, query: "ten minutes")
            #expect(found.map(\.title) == ["billing-service"])
        }
    }
}
