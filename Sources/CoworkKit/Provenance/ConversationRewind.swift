import Foundation

/// Everything one conversation did to your files, and putting it all back.
///
/// Claude Code saves each file before it first changes it in a session, so the earliest version
/// a conversation saved is the file as it was before that conversation touched it — or proof
/// that the file didn't exist yet. That survives the session ending, compaction, and (with Kept)
/// Claude Code's 30-day cleanup.
public struct ConversationChanges: Sendable {

    public struct File: Sendable, Identifiable, Equatable {
        public var id: String { path }
        public let path: String
        /// The file as it was before the conversation first changed it, when Claude Code saved it.
        public let before: FileHistory.SavedVersion?
        /// How many versions the conversation saved.
        public let versions: Int
        public let existsNow: Bool
        /// Changed after the conversation last did, by you or by another session.
        public let changedSince: Bool
        public let lastChanged: Date?

        /// The conversation made this file.
        public var created: Bool { before?.didNotExist == true }
        public var canPutBack: Bool {
            guard let before else { return false }
            return before.didNotExist ? existsNow : before.copy != nil
        }
    }

    public let conversationID: String
    public let title: String
    public let files: [File]

    public var puttable: [File] { files.filter(\.canPutBack) }
}

public enum ConversationRewind {

    public static func changes(conversationID: String, index: HistoryIndex,
                               paths: HostPaths = .current) async throws -> ConversationChanges {
        let conversation = try await index.rows("""
            SELECT title, session_id, source_path, last_activity FROM conversations WHERE id = ?
            """, [.text(conversationID)]).first
        let title = conversation?.text(0) ?? "Untitled"
        let session = conversation?.text(1)
        let transcript = conversation?.text(2)

        // The earliest saved version of each file is its state before the conversation.
        var earliest: [String: (version: Int, backup: String?, time: Date?, count: Int, latest: Date?)] = [:]
        for row in try await index.rows("""
            SELECT file_path, version, backup_file, backup_time FROM file_versions
            WHERE conversation_id = ? ORDER BY file_path, version
            """, [.text(conversationID)]) {
            guard let path = row.text(0) else { continue }
            if var seen = earliest[path] {
                seen.count += 1
                seen.latest = max(seen.latest ?? .distantPast, row.date(3) ?? .distantPast)
                earliest[path] = seen
            } else {
                earliest[path] = (Int(row.int(1)), row.text(2), row.date(3), 1, row.date(3))
            }
        }
        // Files it wrote that Claude Code didn't save a copy of still belong in the list.
        var touched: [String: Date] = [:]
        for row in try await index.rows("""
            SELECT file_path, MAX(timestamp) FROM tool_calls
            WHERE conversation_id = ? AND file_path IS NOT NULL AND name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
            GROUP BY file_path
            """, [.text(conversationID)]) {
            if let path = row.text(0) { touched[path] = row.date(1) }
        }

        let fm = FileManager.default
        var files: [ConversationChanges.File] = []
        for path in Set(earliest.keys).union(touched.keys).sorted() {
            let saved = earliest[path]
            let before = saved.map { saved in
                FileHistory.SavedVersion(
                    conversationID: conversationID, conversationTitle: title, sessionID: session,
                    version: saved.version, savedAt: saved.time,
                    copy: saved.backup.flatMap { FileProvenance.locate(backup: $0, session: session, transcript: transcript, paths: paths) },
                    didNotExist: saved.backup == nil)
            }
            let lastChanged = [touched[path], saved?.latest].compactMap { $0 }.max()
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            // A minute's slack: the last edit lands a moment after its record.
            let changedSince = modified.map { modified in lastChanged.map { modified > $0.addingTimeInterval(60) } ?? false } ?? false
            files.append(.init(path: path, before: before, versions: saved?.count ?? 0,
                               existsNow: fm.fileExists(atPath: path), changedSince: changedSince, lastChanged: lastChanged))
        }
        return ConversationChanges(conversationID: conversationID, title: title, files: files)
    }

    /// How the file changed from before the conversation to now, for text files up to 2 MB;
    /// `backwards`, what putting it back would change.
    public static func diff(for file: ConversationChanges.File, backwards: Bool = false) -> LineDiff? {
        func text(_ url: URL?) -> String? {
            guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
                  let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let before = file.before else { return nil }
        let old = before.didNotExist ? "" : text(before.copy)
        let new = file.existsNow ? text(URL(fileURLWithPath: file.path)) : ""
        guard let old, let new else { return nil }
        return backwards ? LineDiff(old: new, new: old) : LineDiff(old: old, new: new)
    }

    /// Puts `files` back as they were before the conversation, in one receipt: what's there now
    /// is saved first (including files the conversation created, which are then taken away),
    /// and Undo in History reverses all of it.
    @discardableResult
    public static func putBack(_ files: [ConversationChanges.File], title: String,
                               paths: HostPaths = .current) throws -> ImportReceipt {
        let fm = FileManager.default
        var receipt = ImportReceipt(direction: .fileRestore, destination: files.first?.path ?? "")
        receipt.title = "Before “\(title)”"
        receipt.itemCount = files.count
        try Undo.save(receipt)
        for file in files where file.canPutBack {
            guard let before = file.before else { continue }
            let target = URL(fileURLWithPath: file.path)
            let existed = fm.fileExists(atPath: file.path)
            if existed {
                try receipt.backUp(target, paths: paths)
                try Undo.save(receipt)
            }
            if before.didNotExist {
                try fm.removeItem(at: target)
            } else if let copy = before.copy {
                try receipt.createDirectories(at: target.deletingLastPathComponent())
                try Undo.save(receipt)
                try AtomicWrite.write(try Data(contentsOf: copy), to: target)
                if !existed { try receipt.recordCreatedFile(at: target) }
            }
            if existed { try receipt.recordModified(at: target) }
            try Undo.save(receipt)
        }
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }
}
