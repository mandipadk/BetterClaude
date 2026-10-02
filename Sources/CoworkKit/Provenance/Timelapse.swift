import Foundation

/// One file through one conversation, version by version: what it looked like before, and
/// after each turn that changed it, with what was asked that turn. Made from the versions
/// Claude Code saved, like a screen recording of the code without the recording.
public struct Timelapse: Sendable {

    public struct Frame: Sendable, Identifiable, Equatable {
        public let id: Int
        /// The file's text at this point; nil when it didn't exist, or when `isMissing`.
        public let text: String?
        public let date: Date?
        /// What was asked in the turn that led here; nil for the first frame, and for the file
        /// as it is now when it changed after the conversation.
        public let prompt: String?
        /// Claude Code saved this version, but its copy is gone or isn't text.
        public var isMissing = false
        /// The file as it is now, changed since the conversation last edited it.
        public var changedSince = false
    }

    public let path: String
    public let frames: [Frame]

    /// The files a conversation changed that have at least one saved version.
    public static func files(conversationID: String, index: HistoryIndex) async throws -> [String] {
        try await index.rows("""
            SELECT file_path FROM file_versions WHERE conversation_id = ? GROUP BY file_path ORDER BY MIN(backup_time)
            """, [.text(conversationID)]).compactMap { $0.text(0) }
    }

    /// Frame 0 is the file before the conversation changed it; each later frame is the next
    /// saved version, and the last is the file as it is now. A version is saved at the start of
    /// the turn that goes on to change it, so the change into frame n was that turn's.
    public static func load(conversationID: String, path: String, index: HistoryIndex,
                            paths: HostPaths = .current) async throws -> Timelapse {
        let conversation = try await index.rows("SELECT session_id, source_path FROM conversations WHERE id = ?",
                                                [.text(conversationID)]).first
        let session = conversation?.text(0)
        let transcript = conversation?.text(1)
        let versions = try await index.rows("""
            SELECT version, backup_file, backup_time, message_id FROM file_versions
            WHERE conversation_id = ? AND file_path = ? ORDER BY version
            """, [.text(conversationID), .text(path)])
        let prompts = try await index.rows("""
            SELECT uuid, text FROM messages WHERE conversation_id = ? AND role = 'user' AND kind = 'message' AND uuid IS NOT NULL
            """, [.text(conversationID)])
        let promptByID = Dictionary(prompts.compactMap { row in row.text(0).map { ($0, row.text(1) ?? "") } },
                                    uniquingKeysWith: { first, _ in first })

        // No backup means the file didn't exist yet; a backup that can't be read wasn't kept.
        func contents(_ backup: String?) -> (text: String?, missing: Bool) {
            guard let backup else { return (nil, false) }
            guard let copy = FileProvenance.locate(backup: backup, session: session, transcript: transcript, paths: paths),
                  let data = try? Data(contentsOf: copy), let text = String(data: data, encoding: .utf8) else { return (nil, true) }
            return (text, false)
        }

        var frames: [Frame] = []
        for (offset, row) in versions.enumerated() {
            // The turn that started when the previous version was saved made this one.
            let prompt = offset == 0 ? nil : versions[offset - 1].text(3).flatMap { promptByID[$0] }
            let saved = contents(row.text(1))
            frames.append(Frame(id: offset, text: saved.text, date: row.date(2), prompt: prompt, isMissing: saved.missing))
        }
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let now = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        let lastPrompt = versions.last?.text(3).flatMap { promptByID[$0] }
        if now != frames.last?.text || frames.isEmpty || frames.last?.isMissing == true {
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let changes = try await ConversationRewind.changes(conversationID: conversationID, index: index, paths: paths)
            let changedSince = changes.files.first { $0.path == path }?.changedSince ?? false
            frames.append(Frame(id: frames.count, text: now, date: modified, prompt: changedSince ? nil : lastPrompt,
                                isMissing: exists && now == nil, changedSince: changedSince))
        }
        return Timelapse(path: path, frames: frames)
    }

    /// What changed into frame `n` from the one before it.
    public func change(into n: Int) -> LineDiff? {
        guard frames.indices.contains(n), n > 0, !frames[n - 1].isMissing, !frames[n].isMissing else { return nil }
        return LineDiff(old: frames[n - 1].text ?? "", new: frames[n].text ?? "")
    }
}
