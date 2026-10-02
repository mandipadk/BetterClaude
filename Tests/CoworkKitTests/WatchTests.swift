import Foundation
import Testing

@testable import CoworkKit

@Suite("Watching folders")
struct WatchTests {

    @Test("A folder that doesn't exist yet is watched once it's created")
    func waitsForMissingFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("later/sessions", isDirectory: true)
        let changes = Locked(0)
        let watcher = try #require(DirectoryWatcher(roots: [missing], latency: 0.1) { changes.withLock { $0 += 1 } })
        defer { watcher.stop() }

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        for _ in 0..<100 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(changes.withLock { $0 } > 0)
        // Now in the stream itself (whose events this process can't see, as it ignores its own).
        #expect(watcher.watching == [missing.path])
    }

    @Test("Codex's sessions are among the folders watched for conversations")
    func watchesCodex() {
        let paths = HostPaths.fixture(at: URL(fileURLWithPath: "/tmp/watch-fixture"))
        #expect(DirectoryWatcher.conversationRoots(for: [], paths: paths).contains {
            $0.path.hasSuffix(".codex/sessions") })
    }
}
