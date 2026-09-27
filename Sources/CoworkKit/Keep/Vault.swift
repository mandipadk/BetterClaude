import CryptoKit
import Darwin
import Foundation

/// Copies of Claude Code conversations, kept before Claude Code's cleanup deletes them.
///
/// Claude Code removes a transcript `cleanupPeriodDays` (30 by default) after it was last
/// written. The vault keeps a copy of each one in Better Claude's own folder, so the
/// conversation can still be read, and put back, after that.
///
/// Copies are APFS clones where the volume allows: they share the original's blocks and take
/// no space until the original changes or is deleted. Content is stored once per SHA-256 no
/// matter how many conversations point at it. Nothing here ever writes into Claude's folders;
/// putting a conversation back goes through ``restore(_:)``, which keeps a receipt.
public enum Vault {

    // MARK: Model

    public struct Version: Codable, Sendable, Hashable {
        public let sha256: String
        public let size: Int64
        /// The original's modification date when this copy was taken.
        public let sourceModified: Date
        public let keptAt: Date
    }

    /// One kept conversation.
    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public let key: String
        /// Where the conversation lives in Claude Code.
        public let sourcePath: String
        public let sessionId: String
        public var title: String
        public var projectPath: String?
        public var installID: String?
        public var versions: [Version]

        public var id: String { key }
        public var latest: Version? { versions.last }
        public var sourceExists: Bool { FileManager.default.fileExists(atPath: sourcePath) }
    }

    public struct KeepReport: Sendable {
        public var kept = 0
        public var unchanged = 0
        public var failed: [String] = []
    }

    // MARK: Places

    public static var root: URL {
        HostPaths.current.betterClaudeSupport.appendingPathComponent("Kept", isDirectory: true)
    }

    static var objects: URL { root.appendingPathComponent("objects", isDirectory: true) }
    static var entriesDirectory: URL { root.appendingPathComponent("entries", isDirectory: true) }

    public static func objectURL(_ sha256: String) -> URL {
        objects.appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(sha256 + ".jsonl")
    }

    static func key(for sourcePath: String) -> String {
        FileDigest.hex(Data(sourcePath.utf8)).prefix(24).description
    }

    // MARK: Reading

    public static func entries() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: entriesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? decoder.decode(Entry.self, from: data)
        }
    }

    /// The kept copy to read for an entry.
    public static func latestCopy(of entry: Entry) -> URL? {
        guard let latest = entry.latest else { return nil }
        let url = objectURL(latest.sha256)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Bytes the vault takes on disk, counting each stored copy once.
    public static func footprint() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: objects, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Expiry

    /// How long Claude Code keeps a conversation, from its `cleanupPeriodDays` setting.
    public static func cleanupPeriod(configDir: URL = HostPaths.current.claudeCodeConfigDir) -> TimeInterval {
        let settings = configDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settings), let value = try? JSONValue.parse(data),
           let days = value["cleanupPeriodDays"]?.intValue, days > 0 {
            return TimeInterval(days) * 86_400
        }
        return 30 * 86_400
    }

    /// When Claude Code will delete the transcript at `url`, going by when it was last written.
    public static func expiry(of url: URL, period: TimeInterval) -> Date? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        return modified.addingTimeInterval(period)
    }

    // MARK: Keeping

    /// Keeps a copy of each Claude Code conversation that changed since it was last kept.
    /// Cheap to call often: an unchanged transcript costs one `stat`.
    public static func keep(_ conversations: [ConversationRef]) -> KeepReport {
        var report = KeepReport()
        var index = Dictionary(uniqueKeysWithValues: entries().map { ($0.sourcePath, $0) })
        for conversation in conversations {
            guard let session = conversation.claudeCodeSession else { continue }
            let source = session.transcriptURL
            let path = source.standardizedFileURL.path
            do {
                let outcome = try keep(source: source, existing: index[path], title: conversation.title,
                                       sessionId: session.sessionId, projectPath: conversation.projectPath,
                                       installID: conversation.installID)
                if let entry = outcome {
                    index[path] = entry
                    report.kept += 1
                } else {
                    report.unchanged += 1
                }
            } catch {
                report.failed.append("\(conversation.title): \(error)")
            }
        }
        return report
    }

    /// Keeps one transcript file directly.
    @discardableResult
    public static func keep(transcriptAt url: URL, title: String, sessionId: String,
                            projectPath: String?, installID: String) throws -> Entry? {
        let existing = entries().first { $0.sourcePath == url.standardizedFileURL.path }
        return try keep(source: url, existing: existing, title: title, sessionId: sessionId,
                        projectPath: projectPath, installID: installID)
    }

    /// Returns the updated entry, or `nil` when the kept copy is already current.
    static func keep(source: URL, existing: Entry?, title: String, sessionId: String,
                     projectPath: String?, installID: String) throws -> Entry? {
        let before = try attributes(source)
        // Within a second: the entry file stores dates without their fractions. Size does the
        // real work, since a transcript only grows.
        if let latest = existing?.latest, latest.size == before.size,
           abs(latest.sourceModified.timeIntervalSince(before.modified)) < 1 {
            return nil
        }

        try WriteFence.check(root)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporary = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }

        // Clone, then check the original did not move underneath: Claude appends to a
        // transcript while a conversation is running. One retry, then keep what was cloned;
        // the next pass picks up the rest.
        var after = before
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: temporary)
            try clone(source, to: temporary)
            after = try attributes(source)
            if after == before || attempt == 1 { break }
        }

        let sha = try FileDigest.hex(contentsOf: temporary)
        let size = try attributes(temporary).size
        let object = objectURL(sha)
        if !FileManager.default.fileExists(atPath: object.path) {
            try FileManager.default.createDirectory(at: object.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: object)
        }

        var entry = existing ?? Entry(key: key(for: source.standardizedFileURL.path),
                                      sourcePath: source.standardizedFileURL.path, sessionId: sessionId,
                                      title: title, projectPath: projectPath, installID: installID, versions: [])
        entry.title = title
        entry.projectPath = projectPath ?? entry.projectPath
        let version = Version(sha256: sha, size: size, sourceModified: after.modified, keptAt: Date())

        // A transcript only grows, so a copy that is the start of the new one adds nothing:
        // replace it. One that is not — the conversation was rewritten — is kept beside it.
        if let previous = entry.latest, previous.sha256 != sha,
           previous.size < size, (try? prefixDigest(of: object, length: previous.size)) == previous.sha256 {
            entry.versions.removeLast()
            prune(previous.sha256, keepingFor: entry.key)
        }
        if entry.latest?.sha256 != sha { entry.versions.append(version) }
        try save(entry)
        return entry
    }

    // MARK: Restoring

    /// Puts a kept conversation back where Claude Code will find it, with a receipt so it can
    /// be undone. Refuses when something already exists there.
    public static func restore(_ entry: Entry) throws -> ImportReceipt {
        guard let copy = latestCopy(of: entry) else {
            throw TransferError.sourceTranscriptMissing(sessionId: entry.sessionId)
        }
        let destination = URL(fileURLWithPath: entry.sourcePath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TransferError.destinationExists(destination)
        }
        try WriteFence.check(destination)
        var receipt = ImportReceipt(direction: .restore,
                                    destination: "Claude Code · \(destination.deletingLastPathComponent().path)")
        receipt.title = entry.title
        receipt.itemCount = 1
        try Undo.save(receipt)
        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            receipt.recordCreatedDirectory(at: directory)
        }
        try AtomicWrite.write(Data(contentsOf: copy), to: destination)
        try receipt.recordCreatedFile(at: destination)
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }

    /// Forgets a kept conversation and removes its copy unless another entry shares it.
    public static func forget(_ entry: Entry) throws {
        try WriteFence.check(root)
        try? FileManager.default.removeItem(at: entriesDirectory.appendingPathComponent(entry.key + ".json"))
        for version in entry.versions { prune(version.sha256, keepingFor: entry.key) }
    }

    // MARK: Internals

    struct FileState: Equatable {
        let size: Int64
        let modified: Date
    }

    /// Read fresh from the file system every time. `URL.resourceValues` caches per URL
    /// object, so a transcript that grew would keep reporting its old size.
    static func attributes(_ url: URL) throws -> FileState {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileState(size: (values[.size] as? NSNumber)?.int64Value ?? 0,
                         modified: values[.modificationDate] as? Date ?? .distantPast)
    }

    /// An APFS clone when possible, an ordinary copy otherwise.
    static func clone(_ source: URL, to destination: URL) throws {
        if copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func prefixDigest(of url: URL, length: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = length
        while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty {
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hasher.finalize().reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    static func prune(_ sha256: String, keepingFor key: String) {
        let stillUsed = entries().contains { $0.key != key && $0.versions.contains { $0.sha256 == sha256 } }
        guard !stillUsed else { return }
        try? FileManager.default.removeItem(at: objectURL(sha256))
    }

    static func save(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicWrite.write(try encoder.encode(entry),
                              to: entriesDirectory.appendingPathComponent(entry.key + ".json"))
    }
}
