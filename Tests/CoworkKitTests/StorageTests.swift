import CoworkFixtures
import Foundation
import Testing

@testable import CoworkKit

@Suite("Storage")
struct StorageTests {

    @Test("Caches are measured, offered, moved to the Trash, and can be put back")
    func cachesRoundTrip() throws {
        try FixtureHomeTests.withSample { sample in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let categories = Storage.categories(for: claude, coworkConversations: 8)
            let caches = Storage.measure(try #require(categories.first { $0.title == "Caches" }))
            #expect(caches.safety == .reclaimable)
            #expect(caches.bytes >= 9 * 1_048_576)
            #expect(caches.canRemove)

            let removal = try Storage.moveToTrash(caches, install: claude) { false }
            #expect(removal.items.count == 3)
            for item in removal.items {
                #expect(!FileManager.default.fileExists(atPath: item.original))
                #expect(item.trashed.hasPrefix(sample.root.path) || item.trashed.contains("/.Trash/"))
            }
            #expect(Storage.removals().first?.id == removal.id)

            #expect(try Storage.putBack(removal) == 3)
            for item in removal.items { #expect(FileManager.default.fileExists(atPath: item.original)) }
            #expect(Storage.removals().first?.putBack == true)
        }
    }

    @Test("Conversations are shown but never offered, whatever asks")
    func conversationsAreNeverRemoved() throws {
        try FixtureHomeTests.withSample { _ in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let conversations = try #require(Storage.categories(for: claude, coworkConversations: 8)
                .first { $0.title == "Conversations" })
            #expect(conversations.safety == .yours)
            #expect(throws: Storage.StorageError.self) {
                _ = try Storage.moveToTrash(Storage.measure(conversations), install: claude) { false }
            }
        }
    }

    @Test("Nothing moves while the install is open")
    func blockedWhileRunning() throws {
        try FixtureHomeTests.withSample { _ in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let caches = try #require(Storage.categories(for: claude, coworkConversations: 8)
                .first { $0.title == "Caches" })
            #expect(throws: Storage.StorageError.self) {
                _ = try Storage.moveToTrash(caches, install: claude) { true }
            }
            for url in caches.urls { #expect(FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    @Test("A path that escapes the install through a link is refused")
    func refusesEscapes() throws {
        try FixtureHomeTests.withSample { sample in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let outside = sample.root.appendingPathComponent("home/Documents/thesis", isDirectory: true)
            let link = claude.dataRoot.appendingPathComponent("pending-uploads")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let stuck = try #require(Storage.categories(for: claude, coworkConversations: 8)
                .first { $0.title == "Stuck uploads" })
            #expect(throws: Storage.StorageError.self) {
                _ = try Storage.moveToTrash(Storage.measure(stuck), install: claude) { false }
            }
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test("A Cowork machine is offered only by an install with no Cowork conversations")
    func virtualMachineRule() throws {
        try FixtureHomeTests.withSample { _ in
            let claude = try #require(InstallDiscovery.all().first { $0.name == "Claude" })
            let vm = claude.dataRoot.appendingPathComponent("vm_bundles/claudevm.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: vm.appendingPathComponent("rootfs.img"))
            let used = Storage.categories(for: claude, coworkConversations: 8).first { $0.title.hasPrefix("Cowork") }
            let unused = Storage.categories(for: claude, coworkConversations: 0).first { $0.title.hasPrefix("Cowork") }
            #expect(used?.safety == .yours)
            #expect(unused?.safety == .regenerable)
        }
    }
}
