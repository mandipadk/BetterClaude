import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

/// Undo puts back only what Better Claude wrote, and every write leaves what was there before
/// in a state someone can recover.
@Suite("Write safety")
struct WriteSafetyTests {

    // MARK: Undo of a changed file

    @Test("Undo puts a file back while it still holds what was written, and keeps a copy of that first")
    func undoRestoresUnchangedWrite() throws {
        try FixtureHomeTests.withSample { sample in
            let file = sample.root.appendingPathComponent("Documents/notes/CLAUDE.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Notes\n".utf8).write(to: file)

            let receipt = try Corrections.add(["Use tabs."], to: file, paths: sample.paths)
            let written = try FileDigest.hex(contentsOf: file)
            #expect(receipt.modified.first?.sha256After == written)

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "# Notes\n")
            #expect(try Undo.receipts().first { $0.id == receipt.id }?.revertedAt != nil)
            // What Undo replaced is kept, so the undo can be undone by hand.
            #expect(restoresHolding(written, paths: sample.paths))
        }
    }

    @Test("Undo leaves a file someone edited since, and remembers it as undone with that file kept")
    func undoKeepsLaterEdit() throws {
        try FixtureHomeTests.withSample { sample in
            let file = sample.root.appendingPathComponent("Documents/notes/CLAUDE.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Notes\n".utf8).write(to: file)
            let receipt = try Corrections.add(["Use tabs."], to: file, paths: sample.paths)
            let edited = try String(contentsOf: file, encoding: .utf8) + "- My own line\n"
            try Data(edited.utf8).write(to: file)

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.map(\.path) == [file.standardizedFileURL.path])
            #expect(!result.canRetry)
            #expect(try String(contentsOf: file, encoding: .utf8) == edited)
            let recorded = try #require(try Undo.receipts().first { $0.id == receipt.id })
            #expect(recorded.revertedAt != nil)
            #expect(recorded.keptPaths == [file.standardizedFileURL.path])
            #expect(throws: UndoError.self) { try Undo.revertAndRecord(receipt) }
        }
    }

    @Test("A receipt from before fingerprints were kept puts the earlier copy back, keeping what was there aside")
    func oldReceiptRestoresNonDestructively() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let folder = sample.root.appendingPathComponent("Documents/old", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = folder.appendingPathComponent("backup.md")
            try Data("before\n".utf8).write(to: backup)
            let changed = folder.appendingPathComponent("changed.md")
            try Data("someone's later work\n".utf8).write(to: changed)
            let missing = folder.appendingPathComponent("missing.md")

            var receipt = ImportReceipt(direction: .memoryEdit, destination: folder.path, completed: true)
            let before = try FileDigest.hex(contentsOf: backup)
            receipt.modified = [
                .init(path: changed.path, backupPath: backup.path, sha256Before: before),
                .init(path: missing.path, backupPath: backup.path, sha256Before: before),
            ]
            try Undo.save(receipt)

            let replaced = try FileDigest.hex(contentsOf: changed)
            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(Set(result.restored) == [changed.path, missing.path])
            #expect(try String(contentsOf: changed, encoding: .utf8) == "before\n")
            #expect(try String(contentsOf: missing, encoding: .utf8) == "before\n")
            // What was there is kept, so this can't lose anyone's later work.
            #expect(restoresHolding(replaced, paths: sample.paths))
            let recorded = try #require(try Undo.receipts().first { $0.id == receipt.id })
            #expect(recorded.revertedAt != nil)
            #expect(recorded.keptPaths == nil)
        }
    }

    @Test("An old receipt for a file Better Claude changed is undone, not offered forever")
    func oldReceiptForOwnWriteIsUndone() throws {
        try FixtureHomeTests.withSample { sample in
            let file = sample.root.appendingPathComponent("Documents/old/CLAUDE.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Notes\n".utf8).write(to: file)
            var receipt = try Corrections.add(["Use tabs."], to: file, paths: sample.paths)
            // As a 1.3 receipt: no record of what Better Claude left there.
            receipt.modified = receipt.modified.map {
                ImportReceipt.ModifiedFile(path: $0.path, backupPath: $0.backupPath, sha256Before: $0.sha256Before)
            }
            try Undo.save(receipt)
            let written = try FileDigest.hex(contentsOf: file)

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "# Notes\n")
            #expect(restoresHolding(written, paths: sample.paths))
            #expect(try Undo.receipts().first { $0.id == receipt.id }?.revertedAt != nil)
        }
    }

    @Test("An undone change can't be undone twice")
    func refusesSecondUndo() throws {
        try FixtureHomeTests.withSample { sample in
            let file = sample.root.appendingPathComponent("Documents/twice/CLAUDE.md")
            let receipt = try Corrections.add(["Use tabs."], to: file, paths: sample.paths)
            _ = try Undo.revertAndRecord(receipt)
            #expect(throws: UndoError.self) { try Undo.revertAndRecord(receipt) }
        }
    }

    @Test("An undo that keeps a changed copy is recorded as done, with what it kept")
    func partialUndoIsRecorded() throws {
        try FixtureHomeTests.withSample { _ in
            let config = Discovery.defaultClaudeCodeConfigDir()
            let session = try #require(try Discovery.claudeCodeProjects(configDir: config)
                .flatMap { try Discovery.claudeCodeSessions(projectDir: $0, configDir: config) }
                .first { $0.title == "Add a health check endpoint" })
            let transcript = try Transcript(contentsOf: session.transcriptURL)
            let cut = try #require(ConversationBranch.points(in: transcript).first)
            let (plan, branch) = try ConversationBranch.plan(transcript: transcript, cutAt: cut, newTitle: nil)
            let receipt = try ConversationBranch.write(branch, plan: plan)
            let original = try Data(contentsOf: plan.destinationURL)
            try (original + Data("{\"type\":\"user\"}\n".utf8)).write(to: plan.destinationURL)

            let result = try Undo.revertAndRecord(receipt)
            #expect(!result.canRetry)
            #expect(FileManager.default.fileExists(atPath: plan.destinationURL.path))
            let recorded = try #require(try Undo.receipts().first { $0.id == receipt.id })
            #expect(recorded.revertedAt != nil)
            #expect(recorded.keptPaths?.count == result.leftInPlace.count)
            #expect(recorded.keptPaths?.contains(plan.destinationURL.standardizedFileURL.path) == true)
        }
    }

    @Test("An undo that couldn't read a file is left to try again")
    func transientSkipIsRetried() throws {
        try FixtureHomeTests.withSample { sample in
            let folder = sample.root.appendingPathComponent("Documents/locked", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("notes.md")
            try Data("ours\n".utf8).write(to: file)
            var receipt = ImportReceipt(direction: .memoryEdit, destination: folder.path, completed: true)
            try receipt.recordCreatedFile(at: file)
            try Undo.save(receipt)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.canRetry)
            #expect(try Undo.receipts().first { $0.id == receipt.id }?.revertedAt == nil)

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            let second = try Undo.revertAndRecord(receipt)
            #expect(second.leftInPlace.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Folders a change made are taken back with it")
    func parentFoldersRecorded() throws {
        try FixtureHomeTests.withSample { sample in
            try FileManager.default.createDirectory(at: sample.root.appendingPathComponent("Documents"),
                                                    withIntermediateDirectories: true)
            let folder = sample.root.appendingPathComponent("Documents/new-project/docs", isDirectory: true)
            let file = folder.appendingPathComponent("CLAUDE.md")
            let receipt = try Corrections.add(["Use tabs."], to: file, paths: sample.paths)
            #expect(receipt.created.contains { $0.path == folder.standardizedFileURL.path && $0.isDirectory })

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
            #expect(FileManager.default.fileExists(atPath: sample.root.appendingPathComponent("Documents").path))
        }
    }

    // MARK: spaces.json

    @Test("A projects file that can't be read is never written over")
    func unreadableSpacesThrow() throws {
        let org = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: org) }
        let file = SpaceStore.url(inOrg: org)
        let space = SpaceRef(id: "s1", name: "One", folders: ["/tmp/one"])

        for broken in ["{\"spaces\": [", "[1, 2]", "{\"spaces\": {\"id\": \"x\"}}"] {
            try Data(broken.utf8).write(to: file)
            #expect(throws: SpaceStore.Failure.self) { try SpaceStore.add(space, toOrg: org) }
            #expect(throws: SpaceStore.Failure.self) { try SpaceStore.remove(id: "x", fromOrg: org) }
            #expect(try String(contentsOf: file, encoding: .utf8) == broken)
        }

        try FileManager.default.removeItem(at: file)
        #expect(try SpaceStore.add(space, toOrg: org))
        #expect(SpaceStore.spaces(inOrg: org).map(\.id) == ["s1"])
    }

    @Test("An import backs up spaces.json and records each project as it adds it")
    func importBacksUpSpaces() throws {
        try FixtureHomeTests.withSample { sample in
            let (destination, plan) = try projectImportPlan(sample)
            let existing = SpaceRef(id: "mine", name: "Mine", folders: ["/tmp/mine"])
            try SpaceStore.add(existing, toOrg: destination.root)
            let before = try Data(contentsOf: SpaceStore.url(inOrg: destination.root))

            let receipt = try Importer.apply(plan)
            let spacesFile = SpaceStore.url(inOrg: destination.root).standardizedFileURL.path
            let entry = try #require(receipt.modified.first { $0.path == spacesFile })
            #expect(entry.sha256After == (try FileDigest.hex(contentsOf: SpaceStore.url(inOrg: destination.root))))
            #expect(receipt.createdSpaces?.map(\.name) == ["Q4 planning"])

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(try Data(contentsOf: SpaceStore.url(inOrg: destination.root)) == before)
        }
    }

    @Test("When Claude has added a project since, Undo takes out only the one the import added")
    func importUndoAfterLaterProject() throws {
        try FixtureHomeTests.withSample { sample in
            let (destination, plan) = try projectImportPlan(sample)
            try SpaceStore.add(SpaceRef(id: "mine", name: "Mine", folders: ["/tmp/mine"]), toOrg: destination.root)
            let receipt = try Importer.apply(plan)
            try SpaceStore.add(SpaceRef(id: "later", name: "Later", folders: ["/tmp/later"]), toOrg: destination.root)

            let result = try Undo.revertAndRecord(receipt)
            #expect(result.leftInPlace.isEmpty)
            #expect(SpaceStore.spaces(inOrg: destination.root).map(\.id) == ["mine", "later"])
        }
    }

    @Test("A project added before the import fails is on the receipt, so Undo can take it back")
    func spaceRecordedBeforeFailure() throws {
        try FixtureHomeTests.withSample { sample in
            let (destination, plan) = try projectImportPlan(sample)
            let slot = try #require(plan.manifest.sessions.first?.slot)
            try FileManager.default.removeItem(at: BundleReader.slotURL(slot, in: plan.bundleURL)
                .appendingPathComponent("transcript.jsonl"))

            var receiptID: String?
            do {
                _ = try Importer.apply(plan)
                Issue.record("the import should have stopped")
            } catch TransferError.partiallyApplied(let id, _, _) {
                receiptID = id
            }
            let receipt = try #require(try Undo.receipts().first { $0.id == receiptID })
            #expect(receipt.createdSpaces?.map(\.name) == ["Q4 planning"])
            _ = try Undo.revertAndRecord(receipt)
            #expect(SpaceStore.spaces(inOrg: destination.root).isEmpty)
        }
    }

    // MARK: Atomic writes

    @Test("A write through a symlink replaces the file it points to and keeps the link")
    func writeFollowsSymlink() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let folder = sample.root.appendingPathComponent("Documents/links", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let real = folder.appendingPathComponent("real.md")
            try Data("old".utf8).write(to: real)
            let link = folder.appendingPathComponent("CLAUDE.md")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")

            try AtomicWrite.write(Data("new".utf8), to: link)
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "real.md")
            #expect(try String(contentsOf: real, encoding: .utf8) == "new")
        }
    }

    @Test("A relative link is read from the real folder it sits in, not from the path written")
    func relativeLinkThroughLinkedFolder() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let documents = sample.root.appendingPathComponent("Documents", isDirectory: true)
            let realFolder = documents.appendingPathComponent("real/inner", isDirectory: true)
            let sibling = documents.appendingPathComponent("real/shared", isDirectory: true)
            try fm.createDirectory(at: realFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
            let target = sibling.appendingPathComponent("CLAUDE.md")
            try Data("old".utf8).write(to: target)
            try fm.createSymbolicLink(atPath: realFolder.appendingPathComponent("CLAUDE.md").path,
                                      withDestinationPath: "../shared/CLAUDE.md")
            // Seen through this, the link's `..` is `real`, not `Documents`.
            let alias = documents.appendingPathComponent("alias", isDirectory: true)
            try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "real/inner")

            try AtomicWrite.write(Data("new".utf8), to: alias.appendingPathComponent("CLAUDE.md"))
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
            #expect(!fm.fileExists(atPath: documents.appendingPathComponent("shared").path))
            #expect(try fm.destinationOfSymbolicLink(atPath: realFolder.appendingPathComponent("CLAUDE.md").path)
                    == "../shared/CLAUDE.md")
        }
    }

    @Test("A link into a folder that doesn't exist is refused, and no folder is made for it")
    func danglingLinkIsRefused() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let folder = sample.root.appendingPathComponent("Documents/dangling", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let link = folder.appendingPathComponent("CLAUDE.md")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../nowhere/deeper/CLAUDE.md")

            #expect(throws: AtomicWriteError.self) { try AtomicWrite.write(Data("new".utf8), to: link) }
            #expect(!fm.fileExists(atPath: sample.root.appendingPathComponent("Documents/nowhere").path))
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "../nowhere/deeper/CLAUDE.md")
        }
    }

    @Test("A link to a missing file in a folder that exists creates that file")
    func linkToMissingFileInExistingFolder() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let folder = sample.root.appendingPathComponent("Documents/fresh", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let link = folder.appendingPathComponent("CLAUDE.md")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")

            try AtomicWrite.write(Data("new".utf8), to: link)
            #expect(try String(contentsOf: folder.appendingPathComponent("real.md"), encoding: .utf8) == "new")
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "real.md")
        }
    }

    @Test("A replaced file keeps its permissions and extended attributes")
    func writeKeepsMetadata() throws {
        try FixtureHomeTests.withSample { sample in
            let fm = FileManager.default
            let file = sample.root.appendingPathComponent("Documents/settings.json")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            let value = Data("kept".utf8)
            let set = value.withUnsafeBytes { setxattr(file.path, "com.example.kept", $0.baseAddress, value.count, 0, 0) }
            #expect(set == 0)

            try AtomicWrite.write(Data("{\"a\":1}".utf8), to: file)
            #expect(permissions(file) == 0o640)
            var buffer = [UInt8](repeating: 0, count: 16)
            let read = getxattr(file.path, "com.example.kept", &buffer, buffer.count, 0, 0)
            #expect(read == value.count)
            #expect(Data(buffer.prefix(max(read, 0))) == value)
        }
    }

    @Test("New files in a Claude Code folder, and new transcripts, are readable only by you")
    func newPrivateFiles() throws {
        try FixtureHomeTests.withSample { sample in
            let settings = sample.paths.claudeCodeConfigDir.appendingPathComponent("write-safety.json")
            try AtomicWrite.write(Data("{}".utf8), to: settings)
            #expect(permissions(settings) == 0o600)

            let elsewhere = sample.root.appendingPathComponent("Documents/plain.txt")
            try AtomicWrite.write(Data("x".utf8), to: elsewhere)
            #expect(permissions(elsewhere) & 0o044 != 0)

            let transcript = sample.root.appendingPathComponent("Documents/t.jsonl")
            try Transcript(records: [.object(JSONObject([("type", .string("user"))]))]).write(to: transcript)
            #expect(permissions(transcript) == 0o600)
        }
    }

    // MARK: Conversations in use

    @Test("Undo leaves a whole conversation in place once it has been used, and takes back the others")
    func usedConversationStaysWhole() throws {
        try FixtureHomeTests.withSample { sample in
            let work = try #require(try Discovery.stores().first { $0.variantDirName == "Claude Work" })
            let account = try #require(try Discovery.accounts(in: work).first)
            let sessions = try Discovery.sessions(in: account)
            let incident = try #require(sessions.first { $0.title.hasPrefix("Incident write-up") })
            let other = try #require(sessions.first { $0.title == "Q4 hiring plan for the platform team" })
            let folder = sample.root.appendingPathComponent("Documents/In use", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staging = sample.root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let plan = try CoworkPort.plan(name: "In use", space: nil,
                                           conversations: [incident, other].map { CoworkPort.Conversation(session: $0, brief: nil) },
                                           folder: folder, codeTabRoot: nil, staging: staging)
            #expect(plan.isExecutable, "\(plan.importPlan.failures)")
            let receipt = try CoworkPort.apply(plan)

            let used = try #require(plan.importPlan.computed.first { $0.title == incident.title })
            let unused = try #require(plan.importPlan.computed.first { $0.title == other.title })
            let handle = try FileHandle(forWritingTo: used.transcriptURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"next\"}}\n".utf8))
            try handle.close()

            let files = folder.appendingPathComponent("From Cowork/Incident write-up for the Tuesday outage/outputs/incident-2026-09-22.md")
            #expect(FileManager.default.fileExists(atPath: files.path))

            let result = try Undo.revertAndRecord(receipt)
            #expect(!result.leftInPlace.isEmpty)
            #expect(FileManager.default.fileExists(atPath: used.transcriptURL.path))
            #expect(FileManager.default.fileExists(atPath: files.path), "the used conversation keeps its files")
            #expect(!FileManager.default.fileExists(atPath: unused.transcriptURL.path))
        }
    }

    // MARK: Sidecar folders

    @Test("Folder names that APFS would treat as one get told apart")
    func sidecarNamesFoldCase() {
        let names = Importer.sidecarNames(titles: [
            (slot: "a", title: "Notes"), (slot: "b", title: "notes"),
            (slot: "c", title: "Caf\u{E9}"), (slot: "d", title: "Cafe\u{301}"),
            (slot: "e", title: "Plan"),
        ])
        #expect(names["a"] == "Notes (a)")
        #expect(names["b"] == "notes (b)")
        #expect(names["c"] == "Caf\u{E9} (c)")
        #expect(names["d"] == "Cafe\u{301} (d)")
        #expect(names["e"] == "Plan")
    }

    @Test("A conversation's folder that appears after planning is refused, not adopted")
    func sidecarCheckedAtApply() throws {
        try FixtureHomeTests.withSample { sample in
            let (folder, plan) = try codeImportPlan(sample)
            let sidecar = folder.appendingPathComponent("From Cowork/Incident write-up for the Tuesday outage", isDirectory: true)
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
            let own = sidecar.appendingPathComponent("mine.txt")
            try Data("mine".utf8).write(to: own)

            #expect(throws: TransferError.self) { try Importer.apply(plan) }
            #expect(FileManager.default.fileExists(atPath: own.path))
            #expect(!FileManager.default.fileExists(atPath: try #require(plan.computed.first).transcriptURL.path))
        }
    }

    @Test("A folder named for a conversation id counts as taken")
    func folderIdsAreUsed() throws {
        try FixtureHomeTests.withSample { sample in
            let (_, first) = try codeImportPlan(sample)
            let original = try #require(first.manifest.sessions.first?.origin.cliSessionId)
            let computed = try #require(first.computed.first)
            #expect(computed.cliSessionId == original)
            let encodedDir = computed.transcriptURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: encodedDir.appendingPathComponent(original, isDirectory: true),
                                                    withIntermediateDirectories: true)

            let again = try Importer.plan(bundle: first.bundleURL, to: first.endpoint)
            #expect(again.computed.first?.cliSessionId != original)
        }
    }

    // MARK: Code tab records

    @Test("A Code tab record keeps the template's tools but none of its permissions, dated by the conversation")
    func codeTabRecordDropsGrants() throws {
        try FixtureHomeTests.withSample { sample in
            let directory = sample.root.appendingPathComponent("Documents/code-tab", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let template = directory.appendingPathComponent("local_template.json")
            try Data("""
                {"sessionId":"local_template","model":"claude-opus","permissionMode":"bypassPermissions",
                 "enabledMcpTools":{"github":["create_issue"]},"createdAt":1,"lastActivityAt":1,"lastFocusedAt":1}
                """.utf8).write(to: template)
            let lastActivity = Date(timeIntervalSince1970: 1_790_000_000)
            let now = Date(timeIntervalSince1970: 1_790_500_000)

            let url = try CoworkPort.writeCodeTabRecord(copying: template, into: directory, cliSessionId: "c1",
                                                        title: "T", cwd: "/tmp/p", lastActivity: lastActivity, now: now)
            let record = try JSONValue.parse(Data(contentsOf: url))
            #expect(record["permissionMode"]?.stringValue == "default")
            #expect(record["enabledMcpTools"] == nil)
            #expect(record["model"]?.stringValue == "claude-opus")
            #expect(record["createdAt"]?.intValue == 1_790_000_000_000)
            #expect(record["lastActivityAt"]?.intValue == 1_790_000_000_000)
            #expect(record["lastFocusedAt"]?.intValue == 1_790_500_000_000)
        }
    }

    // MARK: From Cowork

    @Test("A From Cowork folder that was already there stays after Undo")
    func existingSidecarRootKept() throws {
        try FixtureHomeTests.withSample { sample in
            let (folder, _) = try codeImportPlan(sample)
            let root = folder.appendingPathComponent("From Cowork", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let work = try #require(try Discovery.stores().first { $0.variantDirName == "Claude Work" })
            let account = try #require(try Discovery.accounts(in: work).first)
            let incident = try #require(try Discovery.sessions(in: account).first { $0.title.hasPrefix("Incident write-up") })
            let staging = sample.root.appendingPathComponent("staging-port", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let plan = try CoworkPort.plan(name: "P", space: nil, conversations: [.init(session: incident, brief: nil)],
                                           folder: folder, codeTabRoot: nil, staging: staging)

            let receipt = try CoworkPort.apply(plan)
            #expect(!receipt.created.contains { $0.path == root.standardizedFileURL.path })
            _ = try Undo.revertAndRecord(receipt)
            #expect(FileManager.default.fileExists(atPath: root.path))
        }
    }

    // MARK: Guards

    @Test("A Chromium lock names a running app only when its process is alive on this Mac")
    func singletonLock() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = folder.appendingPathComponent("SingletonLock").path
        #expect(Guards.lockHolder(userDataDir: folder) == nil)

        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "\(Guards.hostName())-999999")
        #expect(Guards.lockHolder(userDataDir: folder) == nil, "no such process")

        try FileManager.default.removeItem(atPath: lock)
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "another-host.example-\(getpid())")
        #expect(Guards.lockHolder(userDataDir: folder) == nil, "another Mac's lock")
    }

    // MARK: Kept copies

    @Test("A kept copy that's been superseded stays until the entry naming its replacement is saved")
    func vaultSavesBeforePruning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = FixtureHome(root: root)
        sample.iconDonors = [:]
        try sample.make()
        try await HostPaths.$current.withValue(sample.paths) {
            let conversation = try #require(await Catalog(paths: HostPaths.current).snapshot().conversations
                .first { $0.claudeCodeSession != nil && $0.title == "Add a health check endpoint" })
            _ = Vault.keep([conversation])
            let before = try #require(Vault.entries().first { $0.title == "Add a health check endpoint" })
            let oldObject = Vault.objectURL(try #require(before.latest).sha256)

            let url = try #require(conversation.transcriptURL)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"more\"}}\n".utf8))
            try handle.close()

            let entries = Vault.entriesDirectory
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: entries.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entries.path) }
            #expect(!Vault.keep([conversation]).failed.isEmpty)
            #expect(FileManager.default.fileExists(atPath: oldObject.path))
            #expect(Vault.latestCopy(of: before) != nil)
        }
    }

    // MARK: Helpers

    private func permissions(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    private func restoresHolding(_ sha256: String, paths: HostPaths) -> Bool {
        let restores = paths.betterClaudeSupport.appendingPathComponent("Restores", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: restores, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker where (try? FileDigest.hex(contentsOf: url)) == sha256 { return true }
        return false
    }

    /// The Q4 planning project from Claude Work, planned into the Claude install's account.
    private func projectImportPlan(_ sample: FixtureHome) throws -> (AccountRef, ImportPlan) {
        let stores = try Discovery.stores()
        let work = try #require(stores.first { $0.variantDirName == "Claude Work" })
        let claude = try #require(stores.first { $0.variantDirName == "Claude" })
        let source = try #require(try Discovery.accounts(in: work).first)
        let destination = try #require(try Discovery.accounts(in: claude).first)
        let project = try #require(CoworkProjects.projects(in: try Discovery.sessions(in: source))
            .first { $0.name == "Q4 planning" })
        let staging = sample.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = staging.appendingPathComponent("project.coworkbundle")
        _ = try Exporter.write(try Exporter.plan(project.sessions, options: ExportOptions()), to: bundle, profile: .sameUser)
        let plan = try Importer.plan(bundle: bundle, to: .cowork(destination))
        #expect(plan.isExecutable, "\(plan.failures)")
        return (destination, plan)
    }

    /// The incident write-up, with its files, planned into a Claude Code folder.
    private func codeImportPlan(_ sample: FixtureHome) throws -> (URL, ImportPlan) {
        let work = try #require(try Discovery.stores().first { $0.variantDirName == "Claude Work" })
        let account = try #require(try Discovery.accounts(in: work).first)
        let incident = try #require(try Discovery.sessions(in: account).first { $0.title.hasPrefix("Incident write-up") })
        let folder = sample.root.appendingPathComponent("Documents/Incident", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = sample.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var options = ExportOptions(redactionProfile: .sameUser)
        options.includeOutputs = true
        options.includeUploads = true
        let bundle = staging.appendingPathComponent("incident.coworkbundle")
        _ = try Exporter.write(try Exporter.plan([incident], options: options), to: bundle, profile: .sameUser)
        let plan = try Importer.plan(bundle: bundle, to: .claudeCode(projectDir: folder,
                                                                    configDir: HostPaths.current.claudeCodeConfigDir))
        #expect(plan.isExecutable, "\(plan.failures)")
        return (folder, plan)
    }
}
