import Foundation

/// Which conversation a git commit probably came from.
///
/// Nothing records that link, so it's inferred: the conversations that edited the commit's
/// files in the hours before it was made, ranked by how many of those files they changed.
/// Every link says how sure it is.
public struct CommitLink: Sendable, Identifiable, Equatable {
    public var id: String { sha }
    public let sha: String
    public let subject: String
    public let date: Date
    /// The commit's files, as absolute paths.
    public let files: [String]
    public let match: Match?

    public var shortSHA: String { String(sha.prefix(7)) }

    public struct Match: Sendable, Equatable {
        public enum Confidence: String, Sendable { case likely, possible }
        public let conversationID: String
        public let title: String
        public let confidence: Confidence
        /// How many of the commit's files the conversation changed.
        public let filesChanged: Int
    }
}

public enum CommitLinker {

    /// How long before a commit an edit can still be part of it.
    static let window: TimeInterval = 12 * 3_600

    /// The repository a path is in, if any.
    public static func repositoryRoot(for path: String) -> URL? {
        var directory = URL(fileURLWithPath: path)
        if !Discovery.isDirectory(directory) { directory.deleteLastPathComponent() }
        while !Discovery.isDirectory(directory), directory.path != "/" { directory.deleteLastPathComponent() }
        guard let output = git(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : URL(fileURLWithPath: root, isDirectory: true)
    }

    /// Recent commits that changed `path`, each with the conversation it likely came from.
    public static func commits(touching path: String, index: HistoryIndex, limit: Int = 15) async throws -> [CommitLink] {
        guard let root = repositoryRoot(for: path) else { return [] }
        let relative = relativePath(path, to: root)
        return try await link(log(root: root, arguments: ["-n", "\(limit)", "--", relative]), index: index)
    }

    /// Recent commits in the repository at `root`, each with its likely conversation.
    public static func commits(inRepository root: URL, index: HistoryIndex, limit: Int = 30) async throws -> [CommitLink] {
        try await link(log(root: root, arguments: ["-n", "\(limit)"]), index: index)
    }

    struct RawCommit {
        let sha: String
        let date: Date
        let subject: String
        let files: [String]
    }

    static func log(root: URL, arguments: [String]) -> [RawCommit] {
        let separator = "\u{1e}"
        guard let output = git(["log", "--no-merges", "--format=\(separator)%H%x1f%ct%x1f%s", "--name-only"] + arguments,
                               in: root) else { return [] }
        return output.components(separatedBy: separator).compactMap { chunk in
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let header = lines.first else { return nil }
            let fields = header.components(separatedBy: "\u{1f}")
            guard fields.count >= 3, let seconds = TimeInterval(fields[1]) else { return nil }
            let files = lines.dropFirst().map { root.appendingPathComponent($0).path }
            return RawCommit(sha: fields[0], date: Date(timeIntervalSince1970: seconds),
                             subject: fields[2...].joined(separator: "\u{1f}"), files: files)
        }
    }

    static func link(_ commits: [RawCommit], index: HistoryIndex) async throws -> [CommitLink] {
        var links: [CommitLink] = []
        for commit in commits {
            guard !commit.files.isEmpty else {
                links.append(CommitLink(sha: commit.sha, subject: commit.subject, date: commit.date, files: [], match: nil))
                continue
            }
            // Paths as Claude recorded them may go through a symlink the repository doesn't.
            let candidates = Set(commit.files + commit.files.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            let rows = try await index.rows("""
                SELECT t.conversation_id, c.title, COUNT(DISTINCT t.file_path), MAX(t.timestamp)
                FROM tool_calls t JOIN conversations c ON c.id = t.conversation_id
                WHERE t.name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
                  AND t.file_path IN (\(candidates.map { _ in "?" }.joined(separator: ",")))
                  AND t.timestamp BETWEEN ? AND ?
                GROUP BY t.conversation_id ORDER BY COUNT(DISTINCT t.file_path) DESC, MAX(t.timestamp) DESC LIMIT 1
                """, candidates.sorted().map(SQLiteValue.text)
                    + [.date(commit.date.addingTimeInterval(-window)), .date(commit.date.addingTimeInterval(600))])
            var match: CommitLink.Match?
            if let row = rows.first {
                let changed = Int(row.int(2))
                let lastEdit = row.date(3) ?? .distantPast
                let covers = Double(changed) / Double(commit.files.count) >= 0.5
                let close = commit.date.timeIntervalSince(lastEdit) <= 3 * 3_600
                match = CommitLink.Match(conversationID: row.text(0) ?? "", title: row.text(1) ?? "Untitled",
                                         confidence: covers && close ? .likely : .possible, filesChanged: changed)
            }
            links.append(CommitLink(sha: commit.sha, subject: commit.subject, date: commit.date,
                                    files: commit.files, match: match))
        }
        return links
    }

    static func relativePath(_ path: String, to root: URL) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path + "/"
        return resolved.hasPrefix(base) ? String(resolved.dropFirst(base.count)) : path
    }

    /// Runs git read-only, or returns `nil` when git isn't installed or the folder isn't a
    /// repository.
    static func git(_ arguments: [String], in directory: URL) -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return nil }
        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Never ask for anything, and never trip Xcode's first-run prompt.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
