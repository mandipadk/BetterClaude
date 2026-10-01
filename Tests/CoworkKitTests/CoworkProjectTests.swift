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
