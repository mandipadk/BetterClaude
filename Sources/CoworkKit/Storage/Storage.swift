import AppKit
import Foundation

/// Where Claude's disk space goes on this Mac, and which of it can safely go.
///
/// Every category says what it is in plain words and how safe it is to remove. Only
/// `.reclaimable` and `.regenerable` categories are ever offered, and removing one moves it to
/// the Trash rather than deleting it, so it can be put back.
public enum Storage {

    public enum Safety: String, Sendable, Codable {
        /// Caches and leftovers Claude rebuilds or never needs again.
        case reclaimable
        /// Needed, but Claude downloads it again when it next needs it.
        case regenerable
        /// Your conversations, files and settings. Never offered.
        case yours
    }

    public struct Category: Sendable, Identifiable, Hashable {
        public let id: String
        public let installID: String
        public let title: String
        public let explanation: String
        public let safety: Safety
        public let urls: [URL]
        public var bytes: Int64
        /// The measurement stopped early; the real size is at least `bytes`.
        public var isApproximate: Bool
        /// Why it can't be removed right now, when it can't.
        public var blockedReason: String?

        public var canRemove: Bool { safety != .yours && blockedReason == nil && bytes > 0 }
    }

    // MARK: Categories

    /// Every category worth showing for an install. Sizes are filled in by ``measure(_:)``.
    public static func categories(for install: Install, coworkConversations: Int) -> [Category] {
        let root = install.dataRoot
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func existing(_ paths: [String]) -> [URL] {
            paths.map(url).filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        var result: [Category] = []
        func add(_ key: String, _ title: String, _ explanation: String, _ safety: Safety, _ urls: [URL],
                 blocked: String? = nil) {
            guard !urls.isEmpty else { return }
            result.append(Category(id: "\(install.id)#\(key)", installID: install.id, title: title,
                                   explanation: explanation, safety: safety, urls: urls, bytes: 0,
                                   isApproximate: false, blockedReason: blocked))
        }

        switch install.kind {
        case .desktop, .parallex:
            add("conversations", "Conversations",
                "Cowork conversations and the files in their folders.", .yours,
                existing([StoreLayout.sessionsDirName]))
            add("caches", "Caches",
                "Web caches the app rebuilds on its own. Safe to remove.", .reclaimable,
                existing(["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]))
            add("crash-reports", "Crash reports",
                "Reports from past crashes, already sent or never needed.", .reclaimable,
                existing(["Crashpad/completed", "Crashpad/pending"]))
            add("pending-uploads", "Stuck uploads",
                "Attachments that never finished uploading. Nothing uses them.", .reclaimable,
                existing(["pending-uploads"]))
            add("old-cli", "Older Claude Code versions",
                "Copies of Claude Code the app no longer runs. It keeps the newest.", .reclaimable,
                olderVersions(in: url("claude-code")) + olderVersions(in: url("claude-code-vm")))
            add("current-cli", "Claude Code, as bundled",
                "The copy of Claude Code the app runs for its Code tab.", .yours,
                newestVersion(in: url("claude-code")) + newestVersion(in: url("claude-code-vm")))
            let vm = existing(["vm_bundles"])
            if coworkConversations == 0 {
                add("vm", "Cowork's virtual machine",
                    "This install has no Cowork conversations. If you use Cowork here later, Claude downloads the machine again.",
                    .regenerable, vm)
            } else {
                add("vm", "Cowork's virtual machine",
                    "Where Cowork runs, with its working files. Needed while this install has Cowork conversations.",
                    .yours, vm)
            }
            add("extensions", "Extensions", "Desktop extensions you installed.", .yours,
                existing(["Claude Extensions"]))
        case .claudeCode:
            add("conversations", "Conversations",
                "Every Claude Code conversation, by project.", .yours, existing(["projects"]))
            add("skills", "Skills", "Skills you added.", .yours, existing(["skills"]))
            add("plugins", "Plugins", "Installed plugins and their marketplaces.", .yours, existing(["plugins"]))
            add("file-history", "File history",
                "Earlier versions of files Claude Code edited, so a change can be rewound.", .yours,
                existing(["file-history"]))
            add("logs", "Debug logs", "Diagnostic logs Claude Code wrote. Safe to remove.", .reclaimable,
                existing(["debug", "telemetry", "shell-snapshots", "paste-cache"]))
        case .science:
            add("environment", "Python environment",
                "The scientific Python Claude Science runs its analyses in.", .yours, existing(["conda"]))
            add("projects", "Projects", "Your research projects and their files.", .yours, existing(["orgs"]))
        case .external:
            // Better Claude doesn't measure or tidy what other apps keep.
            break
        }
        return result
    }

    static func versionDirectories(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter { Discovery.isDirectory($0) }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
    }

    static func olderVersions(in folder: URL) -> [URL] { Array(versionDirectories(in: folder).dropLast()) }
    static func newestVersion(in folder: URL) -> [URL] { versionDirectories(in: folder).suffix(1) }

    // MARK: Measuring

    /// Allocated size on disk, counting a hard-linked file once. Stops at `deadline` and says
    /// so, rather than keeping the page waiting on a folder with a million files.
    public static func measure(_ category: Category, deadline: TimeInterval = 8) -> Category {
        var measured = category
        let stop = Date().addingTimeInterval(deadline)
        var seen = Set<NSObject>()
        var total: Int64 = 0
        var approximate = false
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]
        outer: for url in category.urls {
            if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
                continue
            }
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true })
            else { continue }
            var count = 0
            for case let file as URL in walker {
                count += 1
                if count % 256 == 0, Date() > stop { approximate = true; break outer }
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                if let identifier = values.fileResourceIdentifier as? NSObject {
                    guard seen.insert(identifier).inserted else { continue }
                }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        measured.bytes = total
        measured.isApproximate = approximate
        return measured
    }

    // MARK: Removing

    public struct Removal: Codable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let installName: String
        public let date: Date
        public let bytes: Int64
        /// Where each item was, and where it went in the Trash.
        public var items: [Item]
        public var putBack: Bool

        public struct Item: Codable, Sendable {
            public let original: String
            public let trashed: String
        }
    }

    public enum StorageError: Error, CustomStringConvertible {
        case notAllowed(String)
        case running(String)

        public var description: String {
            switch self {
            case .notAllowed(let path): return "\(path) isn't something Better Claude removes"
            case .running(let name): return "\(name) is open. Quit it first."
            }
        }
    }

    static var removalsDirectory: URL {
        HostPaths.current.betterClaudeSupport.appendingPathComponent("Removals", isDirectory: true)
    }

    /// Moves a category's items to the Trash and records where each went, so it can be put
    /// back. Every item is checked again right before it moves.
    public static func moveToTrash(_ category: Category, install: Install,
                                   isRunning: () -> Bool) throws -> Removal {
        guard category.safety != .yours else { throw StorageError.notAllowed(category.title) }
        let root = Discovery.canonical(install.dataRoot).path
        var removal = Removal(id: UUID().uuidString, title: category.title, installName: install.name,
                              date: Date(), bytes: category.bytes, items: [], putBack: false)
        for url in category.urls {
            // Inside this install's own folder, after following every link, and never one of
            // the places conversations or credentials live.
            let resolved = Discovery.canonical(url).path
            guard resolved.hasPrefix(root + "/"), !SensitivePaths.isProtected(resolved, installRoot: root) else {
                throw StorageError.notAllowed(url.lastPathComponent)
            }
            guard !isRunning() else { throw StorageError.running(install.name) }
            try WriteFence.check(url)
            let trashed = try trash(url)
            removal.items.append(.init(original: url.path, trashed: trashed.path))
            try save(removal)
        }
        return removal
    }

    /// Moves a removal's items back from the Trash, when they are still there and nothing has
    /// taken their place.
    public static func putBack(_ removal: Removal) throws -> Int {
        var restored = 0
        for item in removal.items where !item.trashed.isEmpty {
            let original = URL(fileURLWithPath: item.original)
            guard FileManager.default.fileExists(atPath: item.trashed),
                  !FileManager.default.fileExists(atPath: original.path) else { continue }
            try WriteFence.check(original)
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: item.trashed), to: original)
            restored += 1
        }
        var updated = removal
        updated.putBack = true
        try save(updated)
        return restored
    }

    /// The Trash, or on a sample Mac the sample's own, so nothing reaches the real one.
    static func trash(_ url: URL) throws -> URL {
        if let root = HostPaths.current.fixtureRoot {
            let bin = root.appendingPathComponent("home/.Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let destination = bin.appendingPathComponent("\(url.lastPathComponent) \(UUID().uuidString.prefix(6))")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }

    public static func removals() -> [Removal] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: removalsDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? decoder.decode(Removal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func save(_ removal: Removal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicWrite.write(try encoder.encode(removal),
                              to: removalsDirectory.appendingPathComponent(removal.id + ".json"))
    }
}

/// Places that hold conversations or credentials. Storage never offers them, whatever a
/// category says.
public enum SensitivePaths {
    static let protectedNames: Set<String> = [
        StoreLayout.sessionsDirName, "claude-code-sessions", "config.json", "projects",
        "Cookies", "Local Storage", "IndexedDB", "encryption.key", ".oauth-tokens",
    ]

    public static func isProtected(_ path: String, installRoot: String) -> Bool {
        let relative = path.dropFirst(installRoot.count + 1)
        return relative.split(separator: "/").contains { protectedNames.contains(String($0)) }
    }
}
