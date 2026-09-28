import Foundation

/// A session in Claude Desktop's Code tab.
///
/// The Code tab runs Claude Code, so the conversation itself is an ordinary Claude Code
/// transcript under `~/.claude/projects`. What the Desktop app adds is this record beside it
/// in `<data>/claude-code-sessions/<account>/<org>/local_<id>.json`: the title it shows, the
/// branch and worktree, whether it is starred. When Claude Code's cleanup deletes the
/// transcript, this record is all that is left.
public struct CodeTabSession: Sendable, Hashable, Identifiable {
    public let metadataURL: URL
    public let sessionId: String
    public let cliSessionId: String
    public let title: String
    public let cwd: String
    public let branch: String?
    public let model: String?
    public let createdAt: Date?
    public let lastActivityAt: Date?
    public let isArchived: Bool
    public let isStarred: Bool
    /// The Desktop app's own note that it could not find the transcript.
    public let transcriptUnavailable: Bool

    public var id: String { metadataURL.path }
}

public enum CodeTabSessions {

    /// Every Code tab session recorded under `root` (an install's `claude-code-sessions`).
    /// A record that will not parse is skipped, never thrown: the app writes these while it
    /// runs.
    public static func sessions(in root: URL) -> [CodeTabSession] {
        var result: [CodeTabSession] = []
        for accountDir in children(of: root) where StoreLayout.isAccountDirName(accountDir.lastPathComponent) {
            for orgDir in children(of: accountDir) where StoreLayout.isAccountDirName(orgDir.lastPathComponent) {
                for file in children(of: orgDir) where Discovery.isSessionMetadataName(file.lastPathComponent) {
                    if let session = session(at: file) { result.append(session) }
                }
            }
        }
        return result
    }

    static func session(at url: URL) -> CodeTabSession? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONValue.parse(data),
              let cliSessionId = value["cliSessionId"]?.stringValue, !cliSessionId.isEmpty
        else { return nil }
        let stem = String(url.lastPathComponent.dropLast(5))
        return CodeTabSession(
            metadataURL: url,
            sessionId: value["sessionId"]?.stringValue ?? stem,
            cliSessionId: cliSessionId,
            title: value["title"]?.stringValue ?? "",
            cwd: value["cwd"]?.stringValue ?? value["originCwd"]?.stringValue ?? "",
            branch: value["branch"]?.stringValue,
            model: value["model"]?.stringValue,
            createdAt: MetadataDocument.date(fromMilliseconds: value["createdAt"]?.intValue),
            lastActivityAt: MetadataDocument.date(fromMilliseconds: value["lastActivityAt"]?.intValue),
            isArchived: value["isArchived"]?.boolValue ?? false,
            isStarred: value["isStarred"]?.boolValue ?? false,
            transcriptUnavailable: value["transcriptUnavailable"]?.boolValue ?? false)
    }

    static func children(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The account a Code tab session was made in: its record sits in
    /// `claude-code-sessions/<account>/<org>/`.
    public static func accountID(of record: CodeTabSession, root: URL) -> String? {
        let parts = record.metadataURL.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard parts.count >= base.count + 3, Array(parts.prefix(base.count)) == base else { return nil }
        return parts[base.count]
    }
}
