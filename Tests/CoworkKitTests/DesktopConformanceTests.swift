import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// What Better Claude writes into Claude Desktop has to be a record the app accepts, not just one
/// Better Claude can read back. Claude skips a task record that lacks a field it expects, without
/// an error, so a copy can succeed here and never appear there.
@Suite("Records Claude Desktop accepts")
struct DesktopConformanceTests {

    /// The fields every native task in `account` has that `record` lacks.
    private func missing(in record: JSONValue, account: AccountRef, besides imported: URL) throws -> [String] {
        let natives = try Discovery.sessions(in: account)
            .filter { $0.metadataURL != imported }
            .compactMap { try? JSONValue.parse(Data(contentsOf: $0.metadataURL)).objectValue }
        guard let first = natives.first else { return [] }
        let everywhere = natives.dropFirst().reduce(Set(first.keys)) { $0.intersection($1.keys) }
        return everywhere.filter { record[$0] == nil }.sorted()
    }

    private func check(_ receipt: ImportReceipt, account: AccountRef) throws {
        let url = try #require(receipt.created.map { URL(fileURLWithPath: $0.path) }
            .first { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" })
        let record = try JSONValue.parse(Data(contentsOf: url))
        for (key, _) in Importer.requiredByDesktop {
            #expect(record[key] != nil, "missing \(key)")
        }
        #expect(record["userSelectedFolders"]?.arrayValue != nil, "Claude requires a list here")
        #expect(record["sessionId"]?.stringValue != nil && record["cwd"]?.stringValue != nil)
        // Fields the app writes on every task; values may be empty, but the field is there.
        let gaps = try missing(in: record, account: account, besides: url)
            .filter { !["accountName", "emailAddress", "spaceId", "spaceIdSetBy"].contains($0) }
        #expect(gaps.isEmpty, "fields native tasks have that the copy lacks: \(gaps)")
    }

    @Test("A Claude Code conversation copied into Claude Desktop has the record shape the app expects")
    func claudeCodeIntoDesktop() throws {
        try FixtureHomeTests.withSample { sample in
            let claude = try #require(try Discovery.stores().first { $0.variantDirName == "Claude" })
            let account = try #require(try Discovery.accounts(in: claude).first)
            let config = Discovery.defaultClaudeCodeConfigDir()
            let session = try #require(try Discovery.claudeCodeProjects(configDir: config)
                .flatMap { try Discovery.claudeCodeSessions(projectDir: $0, configDir: config) }
                .first { $0.title == "Retry failed webhook deliveries with backoff" })
            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bundle = staging.appendingPathComponent("code.coworkbundle")
            _ = try Exporter.write(try Exporter.plan([session], options: ExportOptions()), to: bundle, profile: .sameUser)
            let plan = try Importer.plan(bundle: bundle, to: .cowork(account))
            #expect(plan.isExecutable, "\(plan.failures)")
            try check(try Importer.apply(plan), account: account)
        }
    }

    @Test("A Cowork task copied into another Claude has the record shape the app expects")
    func coworkIntoDesktop() throws {
        try FixtureHomeTests.withSample { sample in
            let stores = try Discovery.stores()
            let work = try #require(stores.first { $0.variantDirName == "Claude Work" })
            let claude = try #require(stores.first { $0.variantDirName == "Claude" })
            let source = try #require(try Discovery.accounts(in: work).first)
            let account = try #require(try Discovery.accounts(in: claude).first)
            let session = try #require(try Discovery.sessions(in: source).first)
            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bundle = staging.appendingPathComponent("cowork.coworkbundle")
            _ = try Exporter.write(try Exporter.plan([session], options: ExportOptions()), to: bundle, profile: .sameUser)
            let plan = try Importer.plan(bundle: bundle, to: .cowork(account))
            try check(try Importer.apply(plan), account: account)
        }
    }
}
