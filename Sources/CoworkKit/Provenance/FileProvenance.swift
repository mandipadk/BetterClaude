import Foundation

/// Where a file came from: every conversation that read or changed it, and every version
/// Claude Code saved of it before changing it.
public struct FileHistory: Sendable {
    public let path: String
    /// Saved versions, oldest first.
    public let versions: [SavedVersion]
    /// Conversations whose tools touched the file, most recent first.
    public let conversations: [Touch]

    public struct SavedVersion: Sendable, Identifiable, Equatable {
        public var id: String { "\(conversationID)#\(version)" }
        public let conversationID: String
        public let conversationTitle: String
        public let sessionID: String?
        public let version: Int
        /// When Claude Code saved it, just before a change.
        public let savedAt: Date?
        /// The saved copy, when it's still on disk (or kept by Better Claude).
        public let copy: URL?
        /// The file didn't exist at this point: this is where it was created, or came back.
        public let didNotExist: Bool
    }

    public struct Touch: Sendable, Identifiable, Equatable {
        public var id: String { conversationID }
        public let conversationID: String
        public let title: String
        public let tools: [String]
        public let lastTouched: Date?
    }

    /// Claude created the file: its earliest saved version is "didn't exist yet".
    public var createdByClaude: Bool { versions.first?.didNotExist == true && versions.first?.version == 1 }
}

/// A file Claude changed recently, for choosing one to look at.
public struct TouchedFile: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let conversations: Int
    public let versions: Int
    public let lastChanged: Date?
}

public enum FileProvenance {

    /// Files Claude wrote or edited, most recently changed first.
    public static func recentFiles(index: HistoryIndex, matching filter: String = "", limit: Int = 200) async throws -> [TouchedFile] {
        let like = "%\(filter.replacingOccurrences(of: "%", with: ""))%"
        let rows = try await index.rows("""
            SELECT file_path, COUNT(DISTINCT conversation_id), 0, MAX(timestamp) FROM tool_calls
            WHERE file_path IS NOT NULL AND name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') AND file_path LIKE ?
            GROUP BY file_path ORDER BY MAX(timestamp) DESC LIMIT ?
            """, [.text(like), .int(Int64(limit))])
        var versions: [String: Int] = [:]
        for row in try await index.rows("SELECT file_path, COUNT(*) FROM file_versions WHERE file_path LIKE ? GROUP BY file_path",
                                        [.text(like)]) {
            versions[row.text(0) ?? ""] = Int(row.int(1))
        }
        return rows.compactMap { row in
            guard let path = row.text(0) else { return nil }
            return TouchedFile(path: path, conversations: Int(row.int(1)), versions: versions[path] ?? 0,
                               lastChanged: row.date(3))
        }
    }

    public static func history(of path: String, index: HistoryIndex, paths: HostPaths = .current) async throws -> FileHistory {
        let rows = try await index.rows("""
            SELECT v.conversation_id, c.title, c.session_id, v.version, v.backup_file, v.backup_time, c.source_path
            FROM file_versions v JOIN conversations c ON c.id = v.conversation_id
            WHERE v.file_path = ? ORDER BY v.backup_time, v.version
            """, [.text(path)])
        let versions = rows.map { row -> FileHistory.SavedVersion in
            let session = row.text(2)
            let backup = row.text(4)
            return FileHistory.SavedVersion(
                conversationID: row.text(0) ?? "", conversationTitle: row.text(1) ?? "Untitled", sessionID: session,
                version: Int(row.int(3)), savedAt: row.date(5),
                copy: backup.flatMap { locate(backup: $0, session: session, transcript: row.text(6), paths: paths) },
                didNotExist: backup == nil)
        }
        let touches = try await index.rows("""
            SELECT t.conversation_id, c.title, GROUP_CONCAT(DISTINCT t.name), MAX(t.timestamp)
            FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
            WHERE t.file_path = ? GROUP BY t.conversation_id ORDER BY MAX(t.timestamp) DESC
            """, [.text(path)]).map {
            FileHistory.Touch(conversationID: $0.text(0) ?? "", title: $0.text(1) ?? "Untitled",
                              tools: ($0.text(2) ?? "").split(separator: ",").map(String.init), lastTouched: $0.date(3))
        }
        return FileHistory(path: path, versions: versions, conversations: touches)
    }

    /// Where a saved copy is: beside the session in Claude Code's config folder, or in
    /// Better Claude's keeping once Claude Code has cleaned it up.
    static func locate(backup: String, session: String?, transcript: String?, paths: HostPaths) -> URL? {
        guard let session else { return nil }
        var candidates: [URL] = []
        if let transcript {
            // <config>/projects/<project>/<session>.jsonl
            let config = URL(fileURLWithPath: transcript).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(config.appendingPathComponent("file-history/\(session)/\(backup)"))
        }
        candidates.append(paths.claudeCodeConfigDir.appendingPathComponent("file-history/\(session)/\(backup)"))
        candidates.append(KeptFileHistory.root(paths: paths).appendingPathComponent("\(session)/\(backup)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Restoring

    public enum RestoreError: Error, CustomStringConvertible {
        case copyMissing
        public var description: String {
            "That version's copy is gone: Claude Code deleted it before Better Claude could keep it."
        }
    }

    /// Puts `version` back at `path`. What's there now is saved first, and the receipt lets
    /// History undo the restore.
    @discardableResult
    public static func restore(_ version: FileHistory.SavedVersion, to path: String,
                               paths: HostPaths = .current) throws -> ImportReceipt {
        let target = URL(fileURLWithPath: path)
        var receipt = ImportReceipt(direction: .restore, destination: path)
        receipt.title = target.lastPathComponent
        receipt.itemCount = 1
        let fm = FileManager.default

        if version.didNotExist {
            // Going back to before the file existed means taking it away. A copy is saved
            // first, and Undo puts it back from there.
            guard fm.fileExists(atPath: path) else { return receipt }
            let saved = try saveCurrent(target, paths: paths)
            receipt.modified.append(.init(path: path, backupPath: saved.path,
                                          sha256Before: try FileDigest.hex(contentsOf: target)))
            try Undo.save(receipt)
            try fm.removeItem(at: target)
        } else {
            guard let copy = version.copy else { throw RestoreError.copyMissing }
            if fm.fileExists(atPath: path) {
                let saved = try saveCurrent(target, paths: paths)
                receipt.modified.append(.init(path: path, backupPath: saved.path,
                                              sha256Before: try FileDigest.hex(contentsOf: target)))
                try Undo.save(receipt)
                try AtomicWrite.write(try Data(contentsOf: copy), to: target)
            } else {
                try Undo.save(receipt)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicWrite.write(try Data(contentsOf: copy), to: target)
                try receipt.recordCreatedFile(at: target)
            }
        }
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }

    static func saveCurrent(_ file: URL, paths: HostPaths) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = paths.betterClaudeSupport.appendingPathComponent("Restores/\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: saved)
        return saved
    }
}

/// Copies of Claude Code's saved file versions and plans, kept before its cleanup deletes
/// them — the same sweep that removes old conversations removes these.
public enum KeptFileHistory {

    public static func root(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Kept/file-history", isDirectory: true)
    }

    public static func plansRoot(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Kept/plans", isDirectory: true)
    }

    public struct Report: Sendable, Equatable {
        public var copied = 0
        public var alreadyKept = 0
    }

    /// Copies every saved version not already kept. Copies are clones where the volume
    /// allows, so they take no space while Claude Code still has the originals.
    @discardableResult
    public static func keep(configDirs: [URL], paths: HostPaths = .current) -> Report {
        var report = Report()
        let fm = FileManager.default
        for config in configDirs {
            let source = config.appendingPathComponent("file-history", isDirectory: true)
            for session in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? [] {
                let destination = root(paths: paths).appendingPathComponent(session.lastPathComponent, isDirectory: true)
                for file in (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? [] {
                    let kept = destination.appendingPathComponent(file.lastPathComponent)
                    // A saved version never changes once written, so one copy is enough.
                    if fm.fileExists(atPath: kept.path) { report.alreadyKept += 1; continue }
                    do {
                        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                        try Vault.clone(file, to: kept)
                        report.copied += 1
                    } catch {
                        continue
                    }
                }
            }
            // Plans are rewritten in place, so each changed plan is kept under its date.
            let plans = config.appendingPathComponent("plans", isDirectory: true)
            for plan in (try? fm.contentsOfDirectory(at: plans, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? [] {
                guard let modified = try? plan.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                let stamp = Int(modified.timeIntervalSince1970)
                let kept = plansRoot(paths: paths).appendingPathComponent(
                    "\(plan.deletingPathExtension().lastPathComponent)@\(stamp).\(plan.pathExtension)")
                if fm.fileExists(atPath: kept.path) { report.alreadyKept += 1; continue }
                try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? Vault.clone(plan, to: kept)) != nil { report.copied += 1 }
            }
        }
        return report
    }
}
