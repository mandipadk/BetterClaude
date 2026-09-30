import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Projects")
struct ProjectsTests {
    @Test("A worktree belongs to its repository")
    func roots() {
        #expect(Projects.root(of: "/Volumes/Sample/app/.claude/worktrees/fix-login") == "/Volumes/Sample/app")
        #expect(Projects.root(of: "/Volumes/Sample/app/") == "/Volumes/Sample/app")
        #expect(Projects.root(of: "/Volumes/Sample/app") == "/Volumes/Sample/app")
    }

    @Test("A project joins its conversations, files, pull request, cost and activity")
    func billingService() async throws {
        try await HistoryIndexTests.withSample { sample, snapshot, index in
            try await index.update(from: snapshot)
            let projects = try await Projects.list(index: index)
            let billing = try #require(projects.first { $0.name == "billing-service" })
            #expect(billing.conversations >= 2)
            #expect(billing.filesChanged >= 2)
            #expect(billing.pullRequests == 1)
            #expect(billing.cost > 0)
            #expect(billing.places.count >= 2)

            let detail = try await Projects.detail(of: billing, index: index, paths: sample.paths, now: sample.now)
            #expect(detail.conversations.contains { $0.title == "Retry failed webhook deliveries with backoff" })
            #expect(detail.pullRequests.first?.name == "northwind/billing-service#318")
            #expect(detail.files.contains { $0.path.hasSuffix("src/webhooks/deliver.ts") })
            #expect(detail.activity.count == 56 && detail.activity.contains { $0.conversations > 0 })
        }
    }
}
