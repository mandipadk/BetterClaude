import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Backup")
struct BackupTests {

    static let password = "lamplight folio marginalia"

    /// Files under `folder`, by relative path; empty folders don't count.
    static func files(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter { path in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        })
    }

    @Test("A backup holds what can't be rebuilt, needs its password, and restores only what's missing")
    func roundTrip() throws {
        try FixtureHomeTests.withSample { sample in
            let support = sample.paths.betterClaudeSupport
            let receipts = support.appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            try Data("{\"id\":\"r1\"}".utf8).write(to: receipts.appendingPathComponent("r1.json"))
            let index = support.appendingPathComponent("Index", isDirectory: true)
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
            try Data("rebuildable".utf8).write(to: index.appendingPathComponent("history-v5.sqlite"))
            let keptFiles = try Self.files(in: support.appendingPathComponent("Kept"))
            #expect(!keptFiles.isEmpty)

            #expect(throws: Backup.Failure.self) {
                try Backup.create(at: sample.root.appendingPathComponent("short.aea"), password: "too short", paths: sample.paths)
            }
            let archive = sample.root.appendingPathComponent("backups/Better Claude.aea")
            let made = try Backup.create(at: archive, password: Self.password, paths: sample.paths)
            #expect(made.files >= 2)
            #expect(try Data(contentsOf: archive).prefix(4) == Data("AEA1".utf8))

            // A new Mac: nothing kept yet, except one receipt it already has in its own form.
            try FileManager.default.removeItem(at: support.appendingPathComponent("Kept"))
            try Data("{\"id\":\"mine\"}".utf8).write(to: receipts.appendingPathComponent("r1.json"))
            try FileManager.default.removeItem(at: index)

            #expect(throws: Backup.Failure.self) {
                try Backup.restore(from: archive, password: "a wrong but long enough password", paths: sample.paths)
            }
            let restored = try Backup.restore(from: archive, password: Self.password, paths: sample.paths)
            #expect(restored.files > 0)
            #expect(try Self.files(in: support.appendingPathComponent("Kept")) == keptFiles)
            // What was already here stays as it was, and the index was never in the backup.
            #expect(try String(contentsOf: receipts.appendingPathComponent("r1.json"), encoding: .utf8) == "{\"id\":\"mine\"}")
            #expect(!FileManager.default.fileExists(atPath: index.path))
        }
    }
}
