import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// The sample Mac is what every screenshot and several engine tests stand on, so it has to
/// read exactly like a real one — and a session reading it must never reach the real one.
@Suite("Sample Mac")
struct FixtureHomeTests {

    static func withSample(_ body: (FixtureHome) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()
        try HostPaths.$current.withValue(sample.paths) { try body(sample) }
    }

    @Test("The engine finds the sample's Claude store and its conversations")
    func discoversTheSample() throws {
        try Self.withSample { sample in
            let stores = try Discovery.stores()
            #expect(stores.map(\.variantDirName).contains("Claude"))
            let claude = try #require(stores.first { $0.variantDirName == "Claude" })
            #expect(claude.launcher?.bundleURL.lastPathComponent == "Claude.app")

            let accounts = try Discovery.accounts(in: claude)
            let account = try #require(accounts.first)
            #expect(account.isSignedIn)
            #expect(account.emailAddress == "alex@rivera.studio")
            let sessions = try Discovery.sessions(in: account)
            #expect(sessions.count == 8)
            #expect(sessions.allSatisfy { $0.transcriptURL != nil })
            #expect(sessions.first?.title == "Plan a three-day trip to Lisbon")
        }
    }

    @Test("Claude Code projects and their titles come from the sample's own config folder")
    func claudeCodeProjects() throws {
        try Self.withSample { sample in
            let config = Discovery.defaultClaudeCodeConfigDir()
            #expect(config.path.hasPrefix(sample.root.path))
            let projects = try Discovery.claudeCodeProjects(configDir: config)
            let titles = try projects.flatMap {
                try Discovery.claudeCodeSessions(projectDir: $0, configDir: config)
            }.map(\.title)
            #expect(titles.contains("Retry failed webhook deliveries with backoff"))
            #expect(titles.contains("Add dark mode to the settings screen"))
            // The Code tab session whose transcript is gone has only its metadata left.
            #expect(!titles.contains("Fix the flaky upload test"))
        }
    }

    @Test("A session reading the sample cannot write outside it")
    func writeFence() throws {
        try Self.withSample { sample in
            let outside = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("bc-fence-\(UUID().uuidString).txt")
            #expect(throws: WriteFenceError.self) {
                try AtomicWrite.write(Data("no".utf8), to: outside)
            }
            #expect(!FileManager.default.fileExists(atPath: outside.path))

            let inside = sample.root.appendingPathComponent("home/inside.txt")
            try AtomicWrite.write(Data("yes".utf8), to: inside)
            #expect(FileManager.default.fileExists(atPath: inside.path))
        }
    }

    @Test("Nothing Claude runs on the real machine counts as running on the sample")
    func noRunningVariants() throws {
        try Self.withSample { _ in
            let running = try Guards.runningVariants()
            #expect(running.isEmpty)
        }
    }

    @Test("A sample is only ever built in an empty folder")
    func refusesNonEmptyFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep me".utf8).write(to: root.appendingPathComponent("existing.txt"))
        #expect(throws: FixtureError.self) { try FixtureHome(root: root).make() }
    }
}
