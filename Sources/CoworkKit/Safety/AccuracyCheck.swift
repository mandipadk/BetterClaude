import Foundation

/// How every number Better Claude shows was arrived at, checked against the disk.
///
/// For each place conversations come from: how many are listed, what was found but left out
/// and why, and anything that doesn't add up. Read only.
public enum AccuracyCheck {

    public struct Source: Sendable, Identifiable {
        public let installID: String
        public let name: String
        public let listed: Int
        public let archived: Int
        /// Of those listed: archived ones are counted under `archived` alone.
        public let withoutMessages: Int
        /// Found on disk but not listed as conversations, each a phrase with its count:
        /// "65 threads Codex started for a conversation".
        public let leftOut: [String]
        public var id: String { installID }
    }

    public struct Issue: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable {
            case duplicateRow, copies, missingMessages, indexBehind, indexAhead, hiddenByDesktop
        }
        public let kind: Kind
        public let title: String
        public let detail: String
        public let count: Int
        public var id: String { kind.rawValue }
    }

    public struct Report: Sendable {
        public let sources: [Source]
        public let issues: [Issue]
        public let checkedAt: Date
        public var total: Int { sources.reduce(0) { $0 + $1.listed } }
    }

    static func phrase(_ count: Int, _ noun: String, _ rest: String, plural: String? = nil) -> String {
        count == 1 ? "1 \(noun) \(rest)" : "\(count) \(noun)s \(plural ?? rest)"
    }

    public static func run(snapshot: CatalogSnapshot, index: HistoryIndex?, now: Date = Date()) async -> Report {
        let byInstall = Dictionary(grouping: snapshot.conversations, by: \.installID)
        let codex = CodexSessions.survey(paths: snapshot.paths)

        var sources: [Source] = []
        for install in snapshot.installs {
            let conversations = byInstall[install.id] ?? []
            var leftOut: [String] = []
            if install.kind == .external(.codex) {
                if let n = codex.counts[.subagent] { leftOut.append(phrase(n, "thread", "Codex started for a conversation")) }
                if let n = codex.counts[.review] { leftOut.append(phrase(n, "automatic review", "of a command", plural: "of commands")) }
                for (program, n) in codex.automatedBy.sorted(by: { $0.value > $1.value }) {
                    leftOut.append(phrase(n, "run", "by \(program)"))
                }
            }
            let agents = conversations.reduce(0) { total, conversation in
                total + (conversation.transcriptURL.map { Subagents.files(beside: $0).count } ?? 0)
            }
            if agents > 0 { leftOut.append(phrase(agents, "sub-agent", "shown inside its conversation", plural: "shown inside their conversations")) }
            sources.append(Source(
                installID: install.id, name: install.name,
                listed: conversations.filter { !$0.isArchived }.count,
                archived: conversations.filter(\.isArchived).count,
                withoutMessages: conversations.filter { !$0.isArchived && $0.isTranscriptMissing }.count,
                leftOut: leftOut))
        }

        var issues: [Issue] = []
        let ids = snapshot.conversations.map(\.id)
        let duplicates = ids.count - Set(ids).count
        if duplicates > 0 {
            issues.append(Issue(kind: .duplicateRow, title: "Rows listed twice",
                                detail: "Two rows share one conversation, which draws blank rows in the list.",
                                count: duplicates))
        }
        // One conversation copied into several Claudes is several conversations, but it helps to
        // know they began as one.
        let copied = Dictionary(grouping: snapshot.conversations.filter { $0.external == nil }, by: \.cliSessionId)
            .filter { !$0.key.isEmpty && Set($0.value.map(\.installID)).count > 1 }
        if !copied.isEmpty {
            issues.append(Issue(kind: .copies, title: "Conversations in more than one place",
                                detail: "Copied or moved between Claudes. Each copy is listed where it is; their usage is counted once.",
                                count: copied.count))
        }
        // Task records a Claude Desktop skips because a field it requires is missing.
        let unshown = snapshot.conversations.filter { conversation in
            guard let session = conversation.coworkSession,
                  let record = try? JSONValue.parse(Data(contentsOf: session.metadataURL)) else { return false }
            return Importer.requiredByDesktop.contains { record[$0.0] == nil }
        }.count
        if unshown > 0 {
            issues.append(Issue(kind: .hiddenByDesktop, title: "Tasks Claude won't show",
                                detail: "Copied by an earlier Better Claude without a field Claude now requires. Undo the copy in Activity and copy it again.",
                                count: unshown))
        }
        let missing = snapshot.conversations.filter { !$0.isArchived && $0.isTranscriptMissing }.count
        if missing > 0 {
            issues.append(Issue(kind: .missingMessages, title: "Conversations without their messages",
                                detail: "The app still has a record of them, but their transcript is gone from this Mac.",
                                count: missing))
        }
        if let index, let rows = try? await index.rows(
            "SELECT id FROM conversations WHERE present = 1") {
            let indexed = Set(rows.compactMap { $0.text(0) })
            let readable = Set(snapshot.conversations
                .filter { $0.transcriptURL != nil || $0.external != nil }.map(\.id))
            let behind = readable.subtracting(indexed).count
            let ahead = indexed.subtracting(Set(ids)).count
            if behind > 0 {
                issues.append(Issue(kind: .indexBehind, title: "Not searchable yet",
                                    detail: "Listed, but the search index hasn't read them yet.", count: behind))
            }
            if ahead > 0 {
                issues.append(Issue(kind: .indexAhead, title: "Searchable but not listed",
                                    detail: "The search index holds conversations the list no longer shows.", count: ahead))
            }
        }
        return Report(sources: sources, issues: issues, checkedAt: now)
    }
}
