import Foundation

/// Another Mac's history, opened from its encrypted backup and read like any other Claude:
/// its kept conversations join the timeline and search, marked as from that Mac. Read-only,
/// and Claude's history tools don't see it.
public enum OtherMacs {

    public struct Mac: Sendable, Codable, Equatable {
        public let name: String
        public let openedAt: Date
    }

    public static func root(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("OtherMacs", isDirectory: true)
    }

    /// Every opened Mac: its folder and what it's called.
    public static func all(paths: HostPaths = .current) -> [(folder: URL, mac: Mac)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root(paths: paths), includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("mac.json")),
                  let mac = try? decoder.decode(Mac.self, from: data) else { return nil }
            return (folder, mac)
        }
        .sorted { $0.mac.name < $1.mac.name }
    }

    /// Opens a backup made on another Mac and keeps its conversations under `name`. Opening a
    /// newer backup of the same Mac replaces the older one.
    @discardableResult
    public static func open(_ backup: URL, password: String, name: String, paths: HostPaths = .current) throws -> Int {
        let fm = FileManager.default
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let folder = root(paths: paths).appendingPathComponent(slug.isEmpty ? "mac" : slug, isDirectory: true)
        let staging = root(paths: paths).appendingPathComponent(".opening-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try Backup.extract(backup, password: password, into: staging)

        let kept = staging.appendingPathComponent("Kept", isDirectory: true)
        guard fm.fileExists(atPath: kept.appendingPathComponent("entries").path) else { return 0 }
        // Built whole beside the old one, then swapped in, so a failure leaves the copy opened
        // last time as it was.
        let built = staging.appendingPathComponent("mac", isDirectory: true)
        try fm.createDirectory(at: built, withIntermediateDirectories: true)
        try fm.moveItem(at: kept, to: built.appendingPathComponent("Kept", isDirectory: true))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AtomicWrite.write(try encoder.encode(Mac(name: name, openedAt: Date())), to: built.appendingPathComponent("mac.json"))
        try AtomicWrite.replaceDirectory(stagedAt: built, with: folder)
        return conversations(in: folder).count
    }

    public static func remove(_ folder: URL, paths: HostPaths = .current) throws {
        guard folder.standardizedFileURL.path.hasPrefix(root(paths: paths).standardizedFileURL.path + "/") else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// A Mac's kept conversations, newest copy of each.
    public static func conversations(in folder: URL) -> [ExternalConversation] {
        let kept = folder.appendingPathComponent("Kept", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? FileManager.default.contentsOfDirectory(at: kept.appendingPathComponent("entries"),
                                                                     includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "json" }.compactMap { url -> ExternalConversation? in
            guard let data = try? Data(contentsOf: url), let entry = try? decoder.decode(Vault.Entry.self, from: data),
                  let latest = entry.latest else { return nil }
            let copy = kept.appendingPathComponent("objects/\(latest.sha256.prefix(2))/\(latest.sha256).jsonl")
            guard FileManager.default.fileExists(atPath: copy.path) else { return nil }
            return ExternalConversation(source: .otherMac, id: "\(folder.lastPathComponent):\(entry.sessionId)",
                                        fileURL: copy, title: entry.title, createdAt: entry.versions.first?.keptAt,
                                        updatedAt: latest.sourceModified, cwd: entry.projectPath, model: nil)
        }
    }
}
