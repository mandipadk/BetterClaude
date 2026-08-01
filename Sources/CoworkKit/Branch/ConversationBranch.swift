import Foundation

/// A point in a conversation you can branch from.
public struct BranchPoint: Sendable, Identifiable, Equatable {
    /// The record uuid. This, not the array position, is what anchors a cut: the
    /// conversation is a `parentUuid` tree and only the uuid identifies a node in it.
    public let id: String
    /// Index among readable messages — the number a person counts when they say
    /// "at message 40". Positions in the full readable list, so it stays stable even
    /// where a message could not be offered as a cut point.
    public let messageIndex: Int
    /// Index in the raw record array.
    public let recordIndex: Int
    public let role: MessageText.Role
    /// First ~120 characters, whitespace collapsed, for the picker.
    public let preview: String
    public let timestamp: Date?

    public init(id: String, messageIndex: Int, recordIndex: Int, role: MessageText.Role,
                preview: String, timestamp: Date?) {
        self.id = id
        self.messageIndex = messageIndex
        self.recordIndex = recordIndex
        self.role = role
        self.preview = preview
        self.timestamp = timestamp
    }
}

public struct BranchPlan: Sendable {
    public let source: URL
    public let cutAt: BranchPoint
    /// Records carried over from the source. The records the branch adds — its origin and
    /// its title — are not counted, so `keptRecords + droppedRecords` is the source's own
    /// record count.
    public let keptRecords: Int
    public let droppedRecords: Int
    public let newSessionId: String
    public let title: String

    public init(source: URL, cutAt: BranchPoint, keptRecords: Int, droppedRecords: Int,
                newSessionId: String, title: String) {
        self.source = source
        self.cutAt = cutAt
        self.keptRecords = keptRecords
        self.droppedRecords = droppedRecords
        self.newSessionId = newSessionId
        self.title = title
    }

    /// A sibling of the source named for the new session id.
    ///
    /// A branch belongs to the same project as the conversation it came from — same cwd,
    /// same encoded project directory — so the only thing that changes is the filename
    /// stem, which is what `--resume <id>` matches.
    public var destinationURL: URL {
        source.deletingLastPathComponent().appendingPathComponent("\(newSessionId).jsonl")
    }
}

public enum BranchError: Error, CustomStringConvertible {
    case noSourceURL
    case pointNotFound(String)
    case chainBroken([String])
    case pickerFilterViolation([PickerViolation])

    public var description: String {
        switch self {
        case .noSourceURL:
            return "this transcript was not read from disk, so a branch has no origin to record"
        case .pointNotFound(let uuid):
            return "no record with uuid \(uuid) in this transcript"
        case .chainBroken(let orphans):
            return "branching would orphan \(orphans.count) record(s): "
                + orphans.prefix(3).joined(separator: ", ")
        case .pickerFilterViolation(let violations):
            return "the branch would be hidden from the resume picker: "
                + violations.prefix(3).map(\.token).joined(separator: ", ")
        }
    }
}

/// Forks a conversation: keep everything up to a chosen message, re-stamp it as a new
/// session, and leave the original untouched.
///
/// The one rule that makes this work rather than merely appear to work: a transcript's
/// logical conversation is a tree threaded by `parentUuid`, and line order is not that
/// tree. Sidechains, retried turns and bookkeeping records are interleaved with the main
/// thread, so truncating by array index keeps records whose parents it just dropped. The
/// result loads, renders as garbage, and gives no error. Everything below walks the chain
/// instead.
public enum ConversationBranch {

    /// Characters of preview kept for the picker.
    public static let previewLimit = 120

    /// The record that tells the UI where a branch came from.
    ///
    /// Deliberately a type neither app knows. Claude Code's reader dispatches on `type`
    /// and ignores what it cannot name, and this package's own chain check skips records
    /// without a `uuid` — so an origin marker costs nothing but is there to be read back.
    public static let originRecordType = "branched-from"

    /// Record types whose payload refers to state that will not exist in the branch.
    ///
    /// The same set the importer drops, for the same reason, and duplicated rather than
    /// shared because the two paths are independently correct: `worktree-state` in
    /// particular carries an `originalCwd` that overrides project-directory derivation.
    static let sidecarTypesToDrop: Set<String> = [
        "worktree-state", "fork-context-ref", "relocated",
        "file-history-snapshot", "file-history-delta", "frame-link", "pr-link",
    ]

    // MARK: - Points

    /// Every point a branch could be taken from — user turns are the useful ones.
    ///
    /// Only messages a person wrote or read: tool calls and tool results carry no prose,
    /// so they never become cut points even though they are records in the chain.
    /// Slash-command scaffolding that the harness writes into the transcript in the user's
    /// voice. It is not something anyone said, so it is never offered as a place to cut.
    static func isMachineText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        for tag in ["command-name", "command-message", "command-args", "local-command-stdout",
                    "local-command-stderr", "system-reminder", "task-notification"]
        where trimmed.hasPrefix("<\(tag)") { return true }
        return false
    }

    public static func points(in transcript: Transcript) -> [BranchPoint] {
        let records = transcript.records
        let messages = ConversationText.messages(in: transcript)
        var out: [BranchPoint] = []
        out.reserveCapacity(messages.count)

        for (messageIndex, message) in messages.enumerated() {
            guard records.indices.contains(message.index),
                  let uuid = records[message.index]["uuid"]?.stringValue,
                  !isMachineText(message.text)
            else { continue }
            out.append(BranchPoint(
                id: uuid,
                messageIndex: messageIndex,
                recordIndex: message.index,
                role: message.role,
                preview: TitleResolver.normalize(message.text, limit: previewLimit) ?? "",
                timestamp: message.timestamp))
        }
        return out
    }

    // MARK: - Truncate

    /// Everything after `point` removed, keeping the ancestor chain intact.
    ///
    /// Returns the transcript unchanged when `point` names a record it does not contain;
    /// ``plan(transcript:cutAt:newTitle:)`` rejects that case rather than silently
    /// producing a copy.
    public static func truncate(_ transcript: Transcript, at point: BranchPoint) -> Transcript {
        let records = transcript.records

        var indexByUuid: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            if let uuid = record["uuid"]?.stringValue, indexByUuid[uuid] == nil {
                indexByUuid[uuid] = index
            }
        }
        guard indexByUuid[point.id] != nil else { return transcript }

        // Walk from the cut back to the root. `insert(_:).inserted` doubles as the cycle
        // guard: a transcript damaged into a loop stops the walk instead of hanging.
        var kept = Set<String>()
        var cursor: String? = point.id
        while let uuid = cursor, kept.insert(uuid).inserted {
            guard let index = indexByUuid[uuid],
                  let parent = records[index]["parentUuid"], !parent.isNull,
                  let parentUuid = parent.stringValue
            else { break }
            cursor = parentUuid
        }

        settleToolCalls(records: records, indexByUuid: indexByUuid, from: point.id, kept: &kept)

        let lastKeptIndex = kept.compactMap { indexByUuid[$0] }.max() ?? point.recordIndex

        var out: [JSONValue] = []
        out.reserveCapacity(kept.count + 8)
        for (index, record) in records.enumerated() {
            if let uuid = record["uuid"]?.stringValue {
                if kept.contains(uuid) { out.append(record); continue }
                // A record with a uuid that is not an ancestor is a sibling branch or a
                // later turn — unless its type puts it outside the tree entirely.
                guard Transcript.bookkeepingRecordTypes.contains(record["type"]?.stringValue ?? "")
                else { continue }
            }
            // Off-chain bookkeeping. It has no parent to orphan, so keeping the part that
            // precedes the cut preserves modes and queued operations without risk.
            if index <= lastKeptIndex { out.append(record) }
        }
        return Transcript(records: out)
    }

    /// Extend the cut forward far enough that no turn the *cut itself* left hanging is
    /// still waiting on a tool.
    ///
    /// An assistant turn that asked for a tool and never received its result is not a
    /// conversation the API will accept on resume — it rejects the request outright. Cuts
    /// land on such turns often, because a turn is routinely one record holding both prose
    /// and a `tool_use` block, so the chain is followed forward to pick the answer up.
    ///
    /// Only children that actually answer something are taken, and the walk stops at the
    /// first one that does not. Real transcripts fork: a tool call whose result sits on a
    /// path the conversation abandoned is left open in the source too, and chasing it would
    /// drag unrelated later records into a branch the reader was told would drop them.
    static func settleToolCalls(records: [JSONValue], indexByUuid: [String: Int],
                                from cut: String, kept: inout Set<String>) {
        var cursor = cut
        var steps = 0
        while steps < 64 {
            steps += 1
            let open = openToolUseIds(in: records, kept: kept)
            guard !open.isEmpty else { return }
            guard let child = firstChild(of: cursor, in: records, skipping: kept),
                  let uuid = records[child]["uuid"]?.stringValue,
                  !toolResultIds(in: records[child]).isDisjoint(with: open)
            else { return }
            kept.insert(uuid)
            cursor = uuid
        }
    }

    static func toolResultIds(in record: JSONValue) -> Set<String> {
        guard let blocks = record["message"]?["content"]?.arrayValue else { return [] }
        var out = Set<String>()
        for block in blocks where block["type"]?.stringValue == "tool_result" {
            if let id = block["tool_use_id"]?.stringValue { out.insert(id) }
        }
        return out
    }

    static func openToolUseIds(in records: [JSONValue], kept: Set<String>) -> Set<String> {
        var requested = Set<String>()
        var answered = Set<String>()
        for record in records {
            guard let uuid = record["uuid"]?.stringValue, kept.contains(uuid) else { continue }
            guard let blocks = record["message"]?["content"]?.arrayValue else { continue }
            for block in blocks {
                switch block["type"]?.stringValue {
                case "tool_use":
                    if let id = block["id"]?.stringValue { requested.insert(id) }
                case "tool_result":
                    if let id = block["tool_use_id"]?.stringValue { answered.insert(id) }
                default:
                    break
                }
            }
        }
        return requested.subtracting(answered)
    }

    static func firstChild(of uuid: String, in records: [JSONValue], skipping kept: Set<String>) -> Int? {
        for (index, record) in records.enumerated() {
            guard record["parentUuid"]?.stringValue == uuid,
                  let child = record["uuid"]?.stringValue, !kept.contains(child)
            else { continue }
            return index
        }
        return nil
    }

    // MARK: - Plan

    /// Truncate at `point` (inclusive) and re-stamp for a new session.
    ///
    /// Throws rather than returning a transcript that would load wrong: an orphaned chain
    /// renders as garbage, and a picker-filtered session is hidden with no error at all.
    public static func plan(transcript: Transcript, cutAt point: BranchPoint,
                            newTitle: String?) throws -> (BranchPlan, Transcript) {
        guard let source = transcript.sourceURL else { throw BranchError.noSourceURL }
        guard transcript.records.contains(where: { $0["uuid"]?.stringValue == point.id })
        else { throw BranchError.pointNotFound(point.id) }

        // Damage already present in the source is not something branching introduced, and
        // refusing to fork an imperfect conversation would be the wrong call — so only
        // newly created orphans are treated as a failure.
        let inheritedOrphans = Set(transcript.chainIntegrity().orphans)
        let sourceSessionId = sessionId(of: transcript)
            ?? source.deletingPathExtension().lastPathComponent
        let newSessionId = UUID().uuidString.lowercased()

        var branch = truncate(transcript, at: point)
        branch.mapRecords { record in
            if let type = record["type"]?.stringValue {
                // Sidecars go after the ancestor walk, not before: removing them first would
                // silently stop the walk at the gap instead of failing loudly further down.
                if sidecarTypesToDrop.contains(type) { return nil }
                // The branch gets exactly one title, and it is not the source's. Leaving the
                // original in would let it win: the resolver takes the last `customTitle` it
                // can parse, and the branch's own copy is not always parseable (below).
                if type == "custom-title" { return nil }
            }
            var r = record
            if r["sessionId"] != nil { r["sessionId"] = .string(newSessionId) }
            if r["session_id"] != nil { r["session_id"] = .string(newSessionId) }
            // `sdk-cli` and friends are filtered out of the resume picker entirely, and a
            // branch nobody can resume is not a branch. `cwd` is deliberately untouched:
            // the branch lives in the same project directory as its source.
            if r["entrypoint"] != nil { r["entrypoint"] = .string("cli") }
            return r
        }
        let keptRecords = branch.records.count

        let title = newTitle.flatMap { TitleResolver.normalize($0, limit: nil) }
            ?? defaultTitle(for: transcript, cutAt: point)

        var origin = JSONObject()
        origin["type"] = .string(originRecordType)
        origin["sessionId"] = .string(newSessionId)
        origin["sourceSessionId"] = .string(sourceSessionId)
        origin["cutUuid"] = .string(point.id)
        origin["cutMessageIndex"] = .int(Int64(point.messageIndex))
        origin["branchedAt"] = .string(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date()))

        // Last, because `customTitle` is the highest-precedence title source and the
        // resolver takes the last one it finds. Without it a branch is indistinguishable
        // from its source in the picker — same opening prompt, same everything.
        var titleRecord = JSONObject()
        titleRecord["type"] = .string("custom-title")
        titleRecord["customTitle"] = .string(title)
        titleRecord["sessionId"] = .string(newSessionId)
        let titleValue = JSONValue.object(titleRecord)

        // And first as well, which is not belt-and-braces but a fix for a real gap. The
        // picker parses whole lines out of a 64 KiB window at each end of the file, and
        // `tailStart` is clamped to the end of the head window — so a file a little over
        // 64 KiB gets a tail of a few dozen bytes that begins mid-record. Every trailing
        // record then fails to parse and the title silently falls through to whatever
        // `ai-title` the source left behind. Line 1 always parses. Duplicate title records
        // are ordinary in real transcripts — the one measured here carries 336 `ai-title`
        // records — and both copies say the same thing, so last-wins is a no-op.
        branch = Transcript(records: [titleValue] + branch.records + [.object(origin), titleValue])

        let orphans = branch.chainIntegrity().orphans.filter { !inheritedOrphans.contains($0) }
        guard orphans.isEmpty else { throw BranchError.chainBroken(orphans) }

        let violations = branch.pickerFilterViolations()
        guard violations.isEmpty else { throw BranchError.pickerFilterViolation(violations) }

        let plan = BranchPlan(
            source: source,
            cutAt: point,
            keptRecords: keptRecords,
            droppedRecords: max(0, transcript.records.count - keptRecords),
            newSessionId: newSessionId,
            title: title)
        return (plan, branch)
    }

    // MARK: - Helpers

    static func sessionId(of transcript: Transcript) -> String? {
        for record in transcript.records {
            if let value = record["sessionId"]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// The source's own title with a suffix, so the two are adjacent in a sorted picker
    /// and still tell apart at a glance.
    static func defaultTitle(for transcript: Transcript, cutAt point: BranchPoint) -> String {
        let (resolved, source) = transcript.resolvedTitle()
        let base = source == .none ? point.preview : resolved
        guard let trimmed = TitleResolver.normalize(base, limit: 160), !trimmed.isEmpty else {
            return "Branch"
        }
        return "\(trimmed) (branch)"
    }
}
