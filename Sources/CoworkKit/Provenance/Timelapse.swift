import Foundation

/// One file through one conversation, version by version: what it looked like before, and
/// after each turn that changed it, with what was asked that turn. Made from the versions
/// Claude Code saved, like a screen recording of the code without the recording.
public struct Timelapse: Sendable {

    public struct Frame: Sendable, Identifiable, Equatable {
        public let id: Int
        /// The file's text at this point; nil when it didn't exist.
        public let text: String?
        public let date: Date?
        /// What was asked in the turn that led here; nil for the first frame.
        public let prompt: String?
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

        func contents(_ backup: String?) -> String? {
            guard let backup, let copy = FileProvenance.locate(backup: backup, session: session, transcript: transcript, paths: paths),
                  let data = try? Data(contentsOf: copy) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        var frames: [Frame] = []
        for (offset, row) in versions.enumerated() {
            // The turn that started when the previous version was saved made this one.
            let prompt = offset == 0 ? nil : versions[offset - 1].text(3).flatMap { promptByID[$0] }
            frames.append(Frame(id: offset, text: contents(row.text(1)), date: row.date(2), prompt: prompt))
        }
        let now = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { String(data: $0, encoding: .utf8) }
        let lastPrompt = versions.last?.text(3).flatMap { promptByID[$0] }
        if now != frames.last?.text || frames.isEmpty {
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            frames.append(Frame(id: frames.count, text: now, date: modified, prompt: lastPrompt))
        }
        return Timelapse(path: path, frames: frames)
    }

    /// What changed into frame `n` from the one before it.
    public func change(into n: Int) -> LineDiff? {
        guard frames.indices.contains(n), n > 0 else { return nil }
        return LineDiff(old: frames[n - 1].text ?? "", new: frames[n].text ?? "")
    }
}
