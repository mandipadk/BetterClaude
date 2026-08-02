import Foundation
import Testing

@testable import CoworkKit

/// A conversation is attached to folders two ways: `userSelectedFolders` on the session, and a
/// `spaceId` naming a Project that owns a folder list. Spaces live per organisation, so a
/// conversation moved to another install used to arrive naming a project the destination had
/// never heard of — and Claude Desktop reported the folder as no longer connected.
@Suite("Spaces and folders")
struct SpaceTests {

    private func makeOrg() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Spaces round-trip through spaces.json")
    func readBack() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }

        #expect(SpaceStore.spaces(inOrg: org).isEmpty, "a store with no projects is normal")

        let space = SpaceRef(id: "space-1", name: "Aunt's Nursing",
                             folders: ["/Users/x/Documents/Claude/Projects/Aunt's Nursing"])
        #expect(try SpaceStore.add(space, toOrg: org))
        let read = SpaceStore.spaces(inOrg: org)
        #expect(read.count == 1)
        #expect(read.first?.name == "Aunt's Nursing")
        #expect(read.first?.folders == space.folders)

        // Adding the same id twice is a no-op, so a repeated import cannot duplicate it.
        #expect(try SpaceStore.add(space, toOrg: org) == false)
        #expect(SpaceStore.spaces(inOrg: org).count == 1)
    }

    @Test("Adding a space leaves every existing entry untouched")
    func preservesUnknownKeys() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }

        // `projects`, `links` and anything a later Claude release adds must survive: this
        // format accretes keys exactly like the session format does.
        try Data("""
        {"spaces":[{"id":"existing","name":"Kept","folders":[{"path":"/tmp/kept"}],
          "projects":[{"opaque":1}],"links":["x"],"createdAt":123,"updatedAt":456,
          "somethingNew":{"nested":true}}],"topLevelExtra":"kept too"}
        """.utf8).write(to: SpaceStore.url(inOrg: org))

        try SpaceStore.add(SpaceRef(id: "added", name: "Added", folders: ["/tmp/added"]), toOrg: org)

        let root = try JSONValue.parse(Data(contentsOf: SpaceStore.url(inOrg: org)))
        #expect(root["topLevelExtra"]?.stringValue == "kept too")
        let first = try #require(root["spaces"]?.arrayValue?.first)
        #expect(first["somethingNew"]?["nested"]?.boolValue == true)
        #expect(first["links"]?.arrayValue?.count == 1)
        #expect(first["projects"]?.arrayValue?.count == 1)
        #expect(root["spaces"]?.arrayValue?.count == 2)
    }

    @Test("An incoming project reuses, remaps, or is created — never duplicated")
    func matching() {
        let incoming = SpaceRef(id: "from-source", name: "Resume - Internships",
                                folders: ["/Users/x/Projects/Resume"])

        // Same id: already here.
        let same = [SpaceRef(id: "from-source", name: "Renamed Since", folders: [])]
        guard case .sameId(let reused) = SpaceStore.match(incoming, against: same) else {
            Issue.record("expected the existing space to be reused"); return
        }
        #expect(reused.id == "from-source")

        // Different id, same name and folders — the same project by any useful definition,
        // usually because an earlier transfer carried it. Remapping avoids a second project
        // with an identical name.
        let twin = [SpaceRef(id: "local-uuid", name: "Resume - Internships",
                             folders: ["/Users/x/Projects/Resume"])]
        guard case .equivalent(let matched) = SpaceStore.match(incoming, against: twin) else {
            Issue.record("expected an equivalent space to be matched"); return
        }
        #expect(matched.id == "local-uuid")

        // Same name but different folders is a different project.
        let sameName = [SpaceRef(id: "other", name: "Resume - Internships",
                                 folders: ["/somewhere/else"])]
        #expect(SpaceStore.match(incoming, against: sameName) == .absent)
        #expect(SpaceStore.match(incoming, against: []) == .absent)
    }

    @Test("Undo can take back a project this tool created")
    func removal() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }

        try SpaceStore.add(SpaceRef(id: "keep", name: "Keep", folders: []), toOrg: org)
        try SpaceStore.add(SpaceRef(id: "drop", name: "Drop", folders: []), toOrg: org)
        #expect(try SpaceStore.remove(id: "drop", fromOrg: org))
        #expect(SpaceStore.spaces(inOrg: org).map(\.id) == ["keep"])
        // Removing something absent is a no-op rather than an error.
        #expect(try SpaceStore.remove(id: "drop", fromOrg: org) == false)
    }

    @Test("A project's memory is collected under its own slot prefix")
    func spaceMemoryIsCollected() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }

        let memory = org.appendingPathComponent("spaces/space-1/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("# what this project knows".utf8)
            .write(to: memory.appendingPathComponent("MEMORY.md"))
        try Data("# who they are".utf8)
            .write(to: memory.appendingPathComponent("user_profile.md"))

        let collected = Exporter.collectSpaceMemory(orgRoot: org, spaceId: "space-1")
        #expect(collected.count == 2)
        // Its own prefix, kept apart from the session's `memory/`: the two land in different
        // places, one inside the workspace and one beside every conversation in the project.
        #expect(collected.allSatisfy { $0.relativePath.hasPrefix(BundleLayout.spaceMemoryDirName) })
        #expect(collected.contains { $0.relativePath.hasSuffix("MEMORY.md") })

        // A project with no memory yet contributes nothing rather than failing.
        #expect(Exporter.collectSpaceMemory(orgRoot: org, spaceId: "never-used").isEmpty)
    }

    @Test("A malformed spaces.json degrades to no projects rather than throwing")
    func tolerant() throws {
        let org = try makeOrg()
        defer { try? FileManager.default.removeItem(at: org) }
        try Data("{not json".utf8).write(to: SpaceStore.url(inOrg: org))
        #expect(SpaceStore.spaces(inOrg: org).isEmpty)
        // And a space with no id is skipped rather than crashing the list.
        try Data(#"{"spaces":[{"name":"No id"},{"id":"ok","name":"Fine","folders":[]}]}"#.utf8)
            .write(to: SpaceStore.url(inOrg: org))
        #expect(SpaceStore.spaces(inOrg: org).map(\.id) == ["ok"])
    }
}
