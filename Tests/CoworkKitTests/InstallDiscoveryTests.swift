import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Installs and the catalog")
struct InstallDiscoveryTests {

    @Test("Every Claude on the sample Mac is found, Parallex copies included")
    func findsEveryInstall() throws {
        try FixtureHomeTests.withSample { sample in
            let installs = InstallDiscovery.all()
            #expect(installs.map(\.name) == ["Claude", "Claude Work", "Claude Science", "Claude Code"])

            let work = try #require(installs.first { $0.name == "Claude Work" })
            #expect(work.kind == .parallex(slug: "claude-work"))
            #expect(work.appURL?.lastPathComponent == "Claude Work.app")
            #expect(work.badge == Install.Badge(text: "W", colorHex: "#2F6BDE"))
            #expect(work.store?.launcher?.kind == .parallexCopy)
            #expect(work.dataRoot.path.hasSuffix("Parallex/instances/claude-work/data"))

            let claude = try #require(installs.first)
            #expect(claude.appURL?.lastPathComponent == "Claude.app")
            #expect(claude.codeTabRoot != nil)
        }
    }

    @Test("An install's setup includes Cowork plugins kept per organisation")
    func coworkPluginsPerOrganisation() throws {
        try FixtureHomeTests.withSample { _ in
            let installs = InstallDiscovery.all()
            let work = try #require(installs.first { $0.name == "Claude Work" })
            let items = ConfigInventory.items(for: work)
            let plugins = Set(items.filter { $0.kind == .plugin }.map(\.name))
            #expect(plugins.isSuperset(of: ["design@knowledge-work-plugins", "sales@knowledge-work-plugins",
                                            "northwind-handbook"]))
            let skills = Set(items.filter { $0.kind == .skill }.map(\.name))
            #expect(skills.contains("sales-review"))
            #expect(skills.contains("expense-policy"))
            #expect(items.contains { $0.kind == .mcpServer && $0.name == "linear" })

            // Compare sees the Parallex copy as an install of its own.
            let scopes = try ConfigInventory.scopes()
            #expect(scopes.contains { $0.title == "Claude Work" })
        }
    }

    @Test("A Parallex copy's store is offered as a transfer destination")
    func parallexStoreIsAStore() throws {
        try FixtureHomeTests.withSample { _ in
            let stores = try Discovery.stores()
            #expect(stores.contains { $0.variantDirName == "Claude Work" })
            let work = try #require(stores.first { $0.variantDirName == "Claude Work" })
            let account = try #require(try Discovery.accounts(in: work).first)
            #expect(account.emailAddress == "alex@northwind.co")
            #expect(account.isSignedIn)
        }
    }

    @Test("Copies of other apps, and copies without their own data folder, are not installs")
    func ignoresOtherParallexCopies() throws {
        try FixtureHomeTests.withSample { sample in
            let instances = ParallexInstances.instancesDirectory
            let slack = instances.appendingPathComponent("slack-work", isDirectory: true)
            try FileManager.default.createDirectory(at: slack, withIntermediateDirectories: true)
            try Data(#"{"name":"Slack Work","targetBundleID":"com.tinyspeck.slackmacgap","mode":"data-dir"}"#.utf8)
                .write(to: slack.appendingPathComponent("instance.json"))
            let home = instances.appendingPathComponent("claude-home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(#"{"name":"Claude Home","targetBundleID":"com.anthropic.claudefordesktop","mode":"home"}"#.utf8)
                .write(to: home.appendingPathComponent("instance.json"))

            #expect(ParallexInstances.claudeCopies().map(\.name) == ["Claude Work"])
        }
    }

    @Test("The timeline spans every install, newest first, with Code tab sessions attributed to Desktop")
    func timeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()

        let snapshot = await Catalog(paths: sample.paths).snapshot()
        let byInstall = Dictionary(grouping: snapshot.conversations, by: \.installID)
        let claude = try #require(snapshot.installs.first { $0.name == "Claude" })
        let work = try #require(snapshot.installs.first { $0.name == "Claude Work" })
        let cli = try #require(snapshot.installs.first { $0.kind == .claudeCode })

        #expect(byInstall[claude.id]?.count == 10)   // 8 Cowork + 2 Code tab
        #expect(byInstall[work.id]?.count == 5)
        #expect(byInstall[cli.id]?.count == 5)       // not 6: the Code tab claims its own transcript
        #expect(snapshot.conversations.first?.title == "Plan a three-day trip to Lisbon")
        let dates = snapshot.conversations.map(\.lastActivity)
        #expect(dates == dates.sorted(by: >))

        let darkMode = try #require(snapshot.conversations.first { $0.title == "Add dark mode to the settings screen" })
        #expect(darkMode.installID == claude.id)
        #expect(darkMode.isStarred)
        #expect(darkMode.projectName == "journal-app")
        #expect(!darkMode.isTranscriptMissing)

        let flaky = try #require(snapshot.conversations.first { $0.title == "Fix the flaky upload test" })
        #expect(flaky.isTranscriptMissing)
    }

    @Test("A second snapshot reuses summaries and still sees a new transcript")
    func catalogCaches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()

        let catalog = Catalog(paths: sample.paths)
        let first = await catalog.snapshot()
        let existing = try #require(first.conversations.first { $0.title == "Add a health check endpoint" })
        let copy = try #require(existing.transcriptURL).deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.copyItem(at: try #require(existing.transcriptURL), to: copy)

        let second = await catalog.snapshot()
        #expect(second.conversations.count == first.conversations.count + 1)
    }
}
