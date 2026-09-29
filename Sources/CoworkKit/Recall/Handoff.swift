import Foundation

/// A one-page brief of a conversation, to start a fresh one from instead of replaying the
/// whole thing: what it was about, where it got to, what changed, and what came last.
///
/// Built from what the index already holds. Claude's own summaries do the heavy lifting: the
/// summary it wrote at the last compaction and the recaps it wrote when the person stepped
/// away are the best short account of a long conversation there is.
public struct HandoffMaterial: Sendable, Equatable {
    public let title: String
    public let place: String
    public let projectPath: String?
    public let started: Date?
    public let lastActive: Date?
    public let messageCount: Int
    public let firstAsk: String?
    public let lastAsk: String?
    public let lastReply: String?
    public let compactionSummary: String?
    public let recaps: [String]
    public let filesChanged: [String]
}

public enum Handoff {

    public static func material(for conversationID: String, index: HistoryIndex) async throws -> HandoffMaterial? {
        guard let row = try await index.rows("""
            SELECT title, kind, install_name, project_path, first_activity, last_activity, message_count
            FROM conversations WHERE id = ?
            """, [.text(conversationID)]).first else { return nil }
        let id = SQLiteValue.text(conversationID)
        func text(_ sql: String) async throws -> String? {
            try await index.rows(sql, [id]).first?.text(0)
        }
        let firstAsk = try await text("SELECT text FROM messages WHERE conversation_id = ? AND role = 'user' AND kind = 'message' ORDER BY ordinal LIMIT 1")
        let lastAsk = try await text("SELECT text FROM messages WHERE conversation_id = ? AND role = 'user' AND kind = 'message' ORDER BY ordinal DESC LIMIT 1")
        let lastReply = try await text("SELECT text FROM messages WHERE conversation_id = ? AND role = 'assistant' AND kind = 'message' ORDER BY ordinal DESC LIMIT 1")
        let compaction = try await text("SELECT text FROM messages WHERE conversation_id = ? AND kind = 'compaction' ORDER BY ordinal DESC LIMIT 1")
        let recaps = try await index.rows("""
            SELECT text FROM messages WHERE conversation_id = ? AND kind = 'recap' ORDER BY ordinal DESC LIMIT 4
            """, [id]).compactMap { $0.text(0) }.reversed()
        let files = try await index.rows("""
            SELECT file_path FROM tool_calls WHERE conversation_id = ? AND file_path IS NOT NULL
              AND name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
            GROUP BY file_path ORDER BY MAX(timestamp) DESC LIMIT 20
            """, [id]).compactMap { $0.text(0) }
        return HandoffMaterial(
            title: row.text(0) ?? "Untitled", place: HistorySearch.place(kind: row.text(1), install: row.text(2)),
            projectPath: row.text(3), started: row.date(4), lastActive: row.date(5), messageCount: Int(row.int(6)),
            firstAsk: firstAsk, lastAsk: lastAsk == firstAsk ? nil : lastAsk, lastReply: lastReply,
            compactionSummary: compaction, recaps: Array(recaps), filesChanged: files)
    }

    /// The brief as Markdown, straight from the material — no model involved.
    public static func draft(_ m: HandoffMaterial, home: HostPaths = .current, advice: Bool = true) -> String {
        var out = "# Handoff: \(m.title)\n\n"
        var context = "From \(m.place)"
        if let project = m.projectPath { context += ", in \(home.abbreviating(project))" }
        context += ". \(m.messageCount) message\(m.messageCount == 1 ? "" : "s")"
        if let started = m.started, let last = m.lastActive {
            context += ", \(started.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        out += context + ".\n\n"
        if let first = m.firstAsk {
            out += "## What it was about\n\n\(clip(first, 1_200))\n\n"
        }
        if let summary = m.compactionSummary {
            out += "## Where it got to\n\n\(clip(summary, 4_000))\n\n"
        }
        if !m.recaps.isEmpty {
            out += "## Claude's recaps\n\n" + m.recaps.map { "- \(clip($0, 500))" }.joined(separator: "\n") + "\n\n"
        }
        if !m.filesChanged.isEmpty {
            out += "## Files changed\n\n" + m.filesChanged.map { "- `\(home.abbreviating($0))`" }.joined(separator: "\n") + "\n\n"
        }
        if m.lastAsk != nil || m.lastReply != nil {
            out += "## The last exchange\n\n"
            if let ask = m.lastAsk { out += "**Asked:** \(clip(ask, 1_200))\n\n" }
            if let reply = m.lastReply { out += "**Claude:** \(clip(reply, 2_400))\n\n" }
        }
        if advice {
            out += "## Picking up\n\nContinue from the last exchange. Check the files above before changing them again; they may have moved on since.\n"
        }
        return out
    }

    /// For a model rewriting the draft into a tighter brief.
    public static let instructions = """
    You write handoff briefs: a short document that lets someone continue a long conversation \
    in a fresh one without reading it. Use only what the notes say. Write Markdown with these \
    sections, each only if the notes support it: "Goal", "Decisions", "Done", "Open questions", \
    "Next step". Keep file paths and names exactly as written, but don't list the changed \
    files: they're attached separately. Be concrete and brief: bullet points, no preamble, no \
    closing remarks. Start directly with the first section heading, written as "## Goal".
    """

    public static func prompt(_ m: HandoffMaterial, home: HostPaths = .current, budget: Int = 12_000) -> String {
        // Without the closing advice, which a model would otherwise report as a decision.
        "Notes on the conversation \"\(m.title)\":\n\n" + clip(draft(m, home: home, advice: false), budget)
    }

    /// A model's brief from its first section on: the model sometimes opens with a title or
    /// a line about itself, and the brief has a title of its own.
    public static func sectionsOnly(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("### ") }) else {
            return lines.drop { $0.hasPrefix("# ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[first...].filter { $0.trimmingCharacters(in: .whitespaces) != "---" }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clip(_ text: String, _ length: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > length ? String(trimmed.prefix(length)) + "…" : trimmed
    }
}
