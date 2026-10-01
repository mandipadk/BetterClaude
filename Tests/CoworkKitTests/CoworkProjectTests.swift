import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// A Cowork project is a space plus the conversations that name it. Copying one carries every
/// conversation in it together, and the destination ends up with the project once.
@Suite("Copying a Cowork project")
struct CoworkProjectTests {

    @Test("A project is listed with the conversations in it")
    func listing() throws {
        try FixtureHomeTests.withSample { _ in
            let work = try #require(try Discovery.stores().first { $0.variantDirName == "Claude Work" })
            let sessions = try Discovery.accounts(in: work).flatMap { try Discovery.sessions(in: $0) }
            let projects = CoworkProjects.projects(in: sessions)
            let q4 = try #require(projects.first { $0.name == "Q4 planning" })
            #expect(q4.sessions.count == 2)
            #expect(Set(q4.sessions.map(\.title)) == ["Q4 hiring plan for the platform team",
                                                      "Customer interview synthesis: onboarding"])
            // Newest first.
            #expect(q4.sessions.first?.title == "Q4 hiring plan for the platform team")
        }
    }

    @Test("Copying a project creates it once, with every conversation in it, and undo takes it all back")
    func copyAndUndo() throws {
        try FixtureHomeTests.withSample { sample in
            let stores = try Discovery.stores()
            let work = try #require(stores.first { $0.variantDirName == "Claude Work" })
            let claude = try #require(stores.first { $0.variantDirName == "Claude" })
            let source = try #require(try Discovery.accounts(in: work).first)
            let destination = try #require(try Discovery.accounts(in: claude).first)
            let project = try #require(CoworkProjects.projects(in: try Discovery.sessions(in: source))
                .first { $0.name == "Q4 planning" })
            let before = try Discovery.sessions(in: destination).count
            #expect(SpaceStore.spaces(inOrg: destination.root).isEmpty)

            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bundle = staging.appendingPathComponent("project.coworkbundle")
            let export = try Exporter.plan(project.sessions, options: ExportOptions())
            _ = try Exporter.write(export, to: bundle, profile: .sameUser)
            let plan = try Importer.plan(bundle: bundle, to: .cowork(destination))
            #expect(plan.isExecutable)

            let receipt = try Importer.apply(plan)
            #expect(receipt.completed)

            let spaces = SpaceStore.spaces(inOrg: destination.root)
            #expect(spaces.map(\.name) == ["Q4 planning"], "the project exists once, not once per conversation")
            let space = try #require(spaces.first)
            #expect(space.folders == project.space.folders)

            let arrived = try Discovery.sessions(in: destination)
            #expect(arrived.count == before + 2)
            let copied = arrived.filter { s in project.sessions.contains { $0.title == s.title } }
            #expect(copied.count == 2)
            #expect(copied.allSatisfy { CoworkProjects.spaceID(of: $0) == space.id })
            // What the project remembers travels with it.
            let memory = destination.root.appendingPathComponent("spaces/\(space.id)/memory/MEMORY.md")
            #expect(FileManager.default.fileExists(atPath: memory.path))
            // The original stays where it was.
            #expect(try Discovery.sessions(in: source).count >= project.sessions.count)

            _ = try Undo.revertAndRecord(receipt)
            #expect(try Discovery.sessions(in: destination).count == before)
            #expect(SpaceStore.spaces(inOrg: destination.root).isEmpty)
        }
    }
}

/// Cowork tasks on this Mac are going away; a project moves into Claude Code as resumable
/// conversations in its folder, with its files beside them and a CLAUDE.md saying what it is.
@Suite("Moving a Cowork project to Claude Code")
struct CoworkPortTests {

    @Test("Every conversation resumes in the folder, its files land in From Cowork, and undo takes it all back")
    func portAndUndo() throws {
        try FixtureHomeTests.withSample { sample in
            let work = try #require(try Discovery.stores().first { $0.variantDirName == "Claude Work" })
            let account = try #require(try Discovery.accounts(in: work).first)
            let sessions = try Discovery.sessions(in: account)
            let project = try #require(CoworkProjects.projects(in: sessions).first { $0.name == "Q4 planning" })
            // One more with files Claude made, so they have somewhere to land.
            let incident = try #require(sessions.first { $0.title.hasPrefix("Incident write-up") })
            let moving = project.sessions + [incident]

            let folder = sample.root.appendingPathComponent("Documents/Q4 planning", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let own = folder.appendingPathComponent("notes.txt")
            try Data("mine".utf8).write(to: own)
            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let codeTabRoot = try #require(try Discovery.stores().first { $0.variantDirName == "Claude" })
                .userDataDir.appendingPathComponent("claude-code-sessions")

            let plan = try CoworkPort.plan(
                name: project.name, space: project.space,
                conversations: moving.map { CoworkPort.Conversation(session: $0, brief: "## \($0.title)\n\nWhere it got to.") },
                folder: folder, codeTabRoot: codeTabRoot, staging: staging)
            #expect(plan.isExecutable, "\(plan.importPlan.failures)")
            #expect(plan.claudeMD != nil)
            let receipt = try CoworkPort.apply(plan)

            let config = HostPaths.current.claudeCodeConfigDir
            let resumable = try Discovery.claudeCodeSessions(
                projectDir: config.appendingPathComponent("projects/\(PathEncoder.encode(PathEncoder.resolvedPath(folder.path)))"),
                configDir: config)
            #expect(Set(resumable.map(\.title)) == Set(moving.map(\.title)))

            let files = folder.appendingPathComponent("From Cowork/Incident write-up for the Tuesday outage/outputs/incident-2026-09-22.md")
            #expect(FileManager.default.fileExists(atPath: files.path))
            let claudeMD = try String(contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
            #expect(claudeMD.hasPrefix("# Q4 planning"))
            #expect(claudeMD.contains("Q4 hiring plan for the platform team"))
            let brief = try String(contentsOf: plan.brief, encoding: .utf8)
            #expect(brief.contains("Where it got to."))
            let records = CodeTabSessions.sessions(in: codeTabRoot).filter { $0.cwd == PathEncoder.resolvedPath(folder.path) }
            #expect(records.count == moving.count)

            // A second move into the same folder is refused rather than adopting what's there.
            let again = try CoworkPort.plan(name: project.name, space: project.space,
                                            conversations: moving.map { CoworkPort.Conversation(session: $0, brief: nil) },
                                            folder: folder, codeTabRoot: nil,
                                            staging: staging.appendingPathComponent("2"))
            #expect(!again.isExecutable)
            #expect(again.claudeMD == nil, "an existing CLAUDE.md is left alone")

            _ = try Undo.revertAndRecord(receipt)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("CLAUDE.md").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("From Cowork").path))
            #expect(CodeTabSessions.sessions(in: codeTabRoot).filter { $0.cwd == PathEncoder.resolvedPath(folder.path) }.isEmpty)
            #expect(FileManager.default.fileExists(atPath: own.path), "the person's own files are never touched")
            // The tasks themselves were only read.
            #expect(try Discovery.sessions(in: account).count == sessions.count)
        }
    }
}
