import Foundation

/// A memory file: what Claude is told to remember, in Markdown.
public struct MemoryFile: Sendable, Identifiable, Hashable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date?

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

/// Memory that belongs together: everything Claude Code remembers everywhere, for one project,
/// or for one Cowork project.
public struct MemoryGroup: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case everywhere
        case project
        case coworkProject
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// The folder it's about, when there is one.
    public let folder: String?
    public let installID: String?
    public let files: [MemoryFile]
    /// The project folder it's about no longer exists.
    public let isOrphaned: Bool

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// Finds every memory file on the Mac. Read only.
public enum MemoryInventory {

    /// `knownFolders` maps a Claude Code project directory to the working folder its
    /// transcripts recorded, for projects whose name can't be decoded otherwise.
    public static func groups(installs: [Install], knownFolders: [URL: String] = [:]) -> [MemoryGroup] {
        let config = HostPaths.current.claudeCodeConfigDir
        let cli = installs.first { $0.kind == .claudeCode }
        var groups: [MemoryGroup] = []

        let globalFiles = [config.appendingPathComponent("CLAUDE.md")].compactMap(file)
        if !globalFiles.isEmpty {
            groups.append(MemoryGroup(id: "everywhere", kind: .everywhere, title: "Every project",
                                      folder: nil, installID: cli?.id, files: globalFiles, isOrphaned: false))
        }

        // Every folder Claude Code has worked in, from its own record, by encoded name.
        let recorded = recordedProjectFolders()
        var byEncoded: [String: String] = [:]
        for folder in recorded { byEncoded[PathEncoder.encode(folder)] = folder }
        for (directory, folder) in knownFolders { byEncoded[directory.lastPathComponent] = folder }

        var seenFolders = Set<String>()
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        for directory in children(of: projects) where Discovery.isDirectory(directory) {
            let memoryFolder = directory.appendingPathComponent("memory", isDirectory: true)
            var files = markdown(in: memoryFolder)
            let folder = byEncoded[directory.lastPathComponent]
            if let folder { files += projectInstructions(in: folder) }
            guard !files.isEmpty else { continue }
            if let folder { seenFolders.insert(folder) }
            groups.append(MemoryGroup(
                id: "project:" + directory.lastPathComponent, kind: .project,
                title: folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? directory.lastPathComponent,
                folder: folder, installID: cli?.id, files: files,
                isOrphaned: folder.map { !FileManager.default.fileExists(atPath: $0) } ?? false))
        }

        // Projects with a CLAUDE.md but no memory folder yet.
        for folder in recorded where !seenFolders.contains(folder) {
            let files = projectInstructions(in: folder)
            guard !files.isEmpty else { continue }
            groups.append(MemoryGroup(id: "project:" + PathEncoder.encode(folder), kind: .project,
                                      title: URL(fileURLWithPath: folder).lastPathComponent, folder: folder,
                                      installID: cli?.id, files: files, isOrphaned: false))
        }

        for install in installs where install.isDesktop {
            guard let store = install.store else { continue }
            for account in children(of: store.sessionsRoot) where StoreLayout.isAccountDirName(account.lastPathComponent) {
                for org in children(of: account) where StoreLayout.isAccountDirName(org.lastPathComponent) {
                    for space in SpaceStore.spaces(inOrg: org) {
                        let memoryFolder = org.appendingPathComponent("spaces/\(space.id)/memory", isDirectory: true)
                        let files = markdown(in: memoryFolder)
                        guard !files.isEmpty else { continue }
                        let missing = !space.folders.isEmpty
                            && space.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
                        groups.append(MemoryGroup(id: "space:\(install.id):\(space.id)", kind: .coworkProject,
                                                  title: space.name, folder: space.folders.first,
                                                  installID: install.id, files: files, isOrphaned: missing))
                    }
                }
            }
        }
        return groups
    }

    /// Groups whose files mention `query`, reading at most 1 MB of each file.
    public static func search(_ groups: [MemoryGroup], query: String) -> [MemoryGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            group.title.localizedCaseInsensitiveContains(needle) || group.files.contains { file in
                guard let handle = try? FileHandle(forReadingFrom: file.url) else { return false }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 1 << 20)) ?? Data()
                return String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains(needle)
            }
        }
    }

    // MARK: Internals

    static func recordedProjectFolders() -> [String] {
        let record = HostPaths.current.home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: record), let root = try? JSONValue.parse(data),
              let projects = root["projects"]?.objectValue else { return [] }
        return projects.keys.sorted()
    }

    static func projectInstructions(in folder: String) -> [MemoryFile] {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        return [root.appendingPathComponent("CLAUDE.md"),
                root.appendingPathComponent(".claude/CLAUDE.md")].compactMap(file)
    }

    static func markdown(in folder: URL) -> [MemoryFile] {
        children(of: folder).filter { $0.pathExtension.lowercased() == "md" }.compactMap(file)
    }

    static func file(_ url: URL) -> MemoryFile? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        return MemoryFile(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
    }

    static func children(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
