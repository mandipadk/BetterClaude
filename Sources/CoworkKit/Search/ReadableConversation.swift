import Foundation

/// A conversation as a person reads it: what each side said, in order, with the tool work in
/// between folded into one line per stretch ("Used 3 tools") instead of dozens of records.
public struct ReadableConversation: Sendable {
    public enum Entry: Sendable, Identifiable {
        case message(MessageText)
        /// Consecutive tool calls between two messages, by tool name in call order.
        case tools(id: String, names: [String])
        /// Where Claude compacted the conversation: everything before is what it no longer
        /// sees, and `summary` is what it kept of it.
        case compaction(Compaction)
        /// A short recap Claude wrote when the person stepped away.
        case recap(id: String, text: String, timestamp: Date?)
        /// One quiet line about something that happened between messages.
        case notice(Notice)

        public var id: String {
            switch self {
            case .message(let message): return message.id
            case .tools(let id, _): return id
            case .compaction(let compaction): return compaction.id
            case .recap(let id, _, _): return id
            case .notice(let notice): return notice.id
            }
        }

        func with(id: String) -> Entry {
            switch self {
            case .message(let m):
                return .message(MessageText(id: id, role: m.role, text: m.text, timestamp: m.timestamp, index: m.index,
                                            attachments: m.attachments))
            case .tools(_, let names): return .tools(id: id, names: names)
            case .compaction(let c):
                return .compaction(Compaction(id: id, timestamp: c.timestamp, trigger: c.trigger,
                                              tokensBefore: c.tokensBefore, tokensAfter: c.tokensAfter, summary: c.summary))
            case .recap(_, let text, let timestamp): return .recap(id: id, text: text, timestamp: timestamp)
            case .notice(let n): return .notice(Notice(id: id, kind: n.kind, text: n.text, timestamp: n.timestamp))
            }
        }
    }

    public struct Compaction: Sendable, Equatable {
        public let id: String
        public let timestamp: Date?
        /// `auto` when Claude ran out of room, `manual` when someone ran /compact.
        public let trigger: String?
        public let tokensBefore: Int?
        public let tokensAfter: Int?
        public var summary: String?
    }

    public struct Notice: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// A slash command the person ran.
            case command
            /// A shell command the person ran with `!`.
            case shell
            /// The person stopped a reply.
            case interrupted
            /// A background task or sub-agent reported back.
            case notification
            /// The reply failed: the API returned an error instead.
            case apiError
            /// The person rewound from here; what came after was dropped.
            case rewound
        }
        public let id: String
        public let kind: Kind
        public let text: String
        public let timestamp: Date?
    }

    /// A pull request Claude Code linked to the conversation.
    public struct PullRequest: Sendable, Hashable {
        public let url: URL
        public let number: Int?
        public let repository: String?

        /// `owner/repo#12`, or the link itself.
        public var name: String {
            guard let number else { return url.absoluteString }
            return repository.map { "\($0)#\(number)" } ?? "#\(number)"
        }
    }

    /// Another conversation this one came from or went on in, by its session id.
    public enum Relative: Sendable, Hashable {
        case continuedIn(String)
        case forkedFrom(String)
    }

    public let entries: [Entry]
    public private(set) var pullRequests: [PullRequest] = []
    public private(set) var relatives: [Relative] = []
    /// The model that answered most recently, as recorded in the transcript.
    public let model: String?
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?

    public var messageCount: Int {
        entries.reduce(0) { count, entry in
            if case .message = entry { return count + 1 }
            return count
        }
    }

    /// A conversation from outside Claude's apps, from its scanned messages.
    public init(scan: TranscriptScan, model: String?) {
        entries = Self.uniquingIDs(scan.messages.enumerated().map { index, message in
            let id = message.uuid ?? "m\(index)"
            switch message.kind {
            case .message:
                return .message(MessageText(id: id, role: message.role, text: message.text,
                                            timestamp: message.timestamp, index: index))
            case .compaction:
                return .compaction(Compaction(id: id, timestamp: message.timestamp, trigger: nil, tokensBefore: nil,
                                              tokensAfter: nil, summary: message.text))
            case .recap:
                return .recap(id: id, text: message.text, timestamp: message.timestamp)
            }
        })
        self.model = model
        firstTimestamp = scan.firstTimestamp
        lastTimestamp = scan.lastTimestamp
    }

    public init(transcript: Transcript) {
        let records = transcript.records
        let chain = ActiveChain(records, isReadable: Self.isReadable)
        var entries: [Entry] = []
        var pendingTools: [String] = []
        var pendingID: String?
        var model: String?
        var first: Date?
        var last: Date?

        func flushTools() {
            guard !pendingTools.isEmpty, let id = pendingID else { return }
            entries.append(.tools(id: "tools-" + id, names: pendingTools))
            pendingTools = []
            pendingID = nil
        }
        func note(_ stamp: Date?) {
            guard let stamp else { return }
            if first == nil { first = stamp }
            last = stamp
        }

        var pullRequests: [PullRequest] = []
        var relatives: [Relative] = []

        for (index, record) in records.enumerated() {
            let uuid = record["uuid"]?.stringValue
            let stamp = record["timestamp"]?.stringValue.flatMap(Transcript.parseTimestamp)
            if chain.rewoundAt.contains(index) {
                flushTools()
                if case .notice(let previous)? = entries.last, previous.kind == .rewound {} else {
                    entries.append(.notice(Notice(id: "rewound-\(uuid ?? "\(index)")", kind: .rewound,
                                                  text: "An earlier attempt was rewound", timestamp: stamp)))
                }
            }
            guard !chain.hidden.contains(index) else { continue }
            switch record["type"]?.stringValue {
            case "pr-link":
                if let link = record["prUrl"]?.stringValue, let url = URL(string: link), url.scheme == "https",
                   !pullRequests.contains(where: { $0.url == url }) {
                    pullRequests.append(PullRequest(url: url, number: record["prNumber"]?.intValue.map(Int.init),
                                                    repository: record["prRepository"]?.stringValue))
                }
                continue
            case "continued-in":
                if let id = record["continuedInSessionId"]?.stringValue, !relatives.contains(.continuedIn(id)) {
                    relatives.append(.continuedIn(id))
                }
                continue
            case "branched-from":
                if let id = record["sourceSessionId"]?.stringValue, !relatives.contains(.forkedFrom(id)) {
                    relatives.append(.forkedFrom(id))
                }
                continue
            case "attachment":
                if let text = TranscriptScanner.queuedPrompt(record) {
                    flushTools()
                    note(stamp)
                    entries.append(.message(MessageText(id: uuid ?? "\(index)", role: .user, text: text,
                                                        timestamp: stamp, index: index)))
                }
                continue
            case "system":
                switch record["subtype"]?.stringValue {
                case "compact_boundary":
                    flushTools()
                    let metadata = record["compactMetadata"]
                    entries.append(.compaction(Compaction(
                        id: uuid ?? "compaction-\(index)", timestamp: stamp,
                        trigger: metadata?["trigger"]?.stringValue,
                        tokensBefore: metadata?["preTokens"]?.intValue.map(Int.init),
                        tokensAfter: metadata?["postTokens"]?.intValue.map(Int.init), summary: nil)))
                case "away_summary":
                    if let text = record["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        flushTools()
                        entries.append(.recap(id: uuid ?? "recap-\(index)", text: text, timestamp: stamp))
                    }
                default:
                    break
                }
                continue
            default:
                break
            }
            // The summary written at a compaction belongs to it, not to the person.
            if record["isCompactSummary"]?.boolValue == true, let message = record["message"] {
                let text = ConversationText.plainText(of: message)
                if let last = entries.lastIndex(where: { if case .compaction = $0 { return true }; return false }),
                   case .compaction(var compaction) = entries[last], compaction.summary == nil {
                    compaction.summary = text
                    entries[last] = .compaction(compaction)
                } else if !text.isEmpty {
                    entries.append(.compaction(Compaction(id: uuid ?? "summary-\(index)",
                                                          timestamp: nil, trigger: nil, tokensBefore: nil,
                                                          tokensAfter: nil, summary: text)))
                }
                continue
            }
            guard let type = record["type"]?.stringValue, type == "user" || type == "assistant",
                  record["isMeta"]?.boolValue != true,
                  let message = record["message"] else { continue }
            let id = uuid ?? "\(index)"

            if type == "assistant" {
                if record["isApiErrorMessage"]?.boolValue == true {
                    let text = ConversationText.plainText(of: message)
                    flushTools()
                    entries.append(.notice(Notice(id: id, kind: .apiError,
                                                  text: text.isEmpty ? "The reply failed" : text, timestamp: stamp)))
                    continue
                }
                note(stamp)
                if let name = message["model"]?.stringValue, name.hasPrefix("claude") { model = name }
                for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                    if pendingID == nil { pendingID = id }
                    pendingTools.append(block["name"]?.stringValue ?? "Tool")
                }
                let text = ConversationText.plainText(of: message)
                guard !text.isEmpty else { continue }
                flushTools()
                entries.append(.message(MessageText(id: id, role: .assistant, text: text, timestamp: stamp, index: index)))
                continue
            }

            let parts = InjectedContext.parts(ofBlocks: ConversationText.textBlocks(of: message))
            let attachments = ConversationText.attachmentNames(of: message)
            for (offset, part) in parts.enumerated() {
                let notice: (Notice.Kind, String)
                switch part {
                case .typed: continue
                case .command(let name, let arguments):
                    notice = (.command, arguments.isEmpty ? "Ran \(name)" : "Ran \(name) \(arguments)")
                case .shell(let command): notice = (.shell, "! \(command)")
                case .interrupted: notice = (.interrupted, "You interrupted Claude")
                case .notification(let summary): notice = (.notification, summary ?? "A background task finished")
                }
                flushTools()
                note(stamp)
                entries.append(.notice(Notice(id: "\(id)-\(offset)", kind: notice.0, text: notice.1, timestamp: stamp)))
            }
            let typed = InjectedContext.typedText(parts) ?? ""
            guard !typed.isEmpty || !attachments.isEmpty else { continue }
            flushTools()
            note(stamp)
            entries.append(.message(MessageText(id: id, role: .user, text: typed, timestamp: stamp, index: index,
                                                attachments: attachments)))
        }
        flushTools()

        self.entries = Self.uniquingIDs(entries)
        self.pullRequests = pullRequests
        self.relatives = relatives
        self.model = model
        self.firstTimestamp = first
        self.lastTimestamp = last
    }

    /// Whether a record shows as something someone said.
    static func isReadable(_ record: JSONValue) -> Bool {
        if TranscriptScanner.queuedPrompt(record) != nil { return true }
        guard let type = record["type"]?.stringValue, type == "user" || type == "assistant",
              record["isMeta"]?.boolValue != true, record["isApiErrorMessage"]?.boolValue != true,
              let message = record["message"] else { return false }
        if type == "assistant" { return !ConversationText.plainText(of: message).isEmpty }
        return InjectedContext.typedText(InjectedContext.parts(ofBlocks: ConversationText.textBlocks(of: message))) != nil
            || !ConversationText.attachmentNames(of: message).isEmpty
    }

    /// Entry ids are what lists key on; a transcript that repeats a record mustn't repeat one.
    static func uniquingIDs(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.map { entry in
            guard seen.insert(entry.id).inserted else {
                var copy = 2
                while !seen.insert("\(entry.id)#\(copy)").inserted { copy += 1 }
                return entry.with(id: "\(entry.id)#\(copy)")
            }
            return entry
        }
    }
}

/// Which records make up the conversation as it stands.
///
/// The transcript is a tree threaded by `parentUuid`: rewinding to an earlier message and
/// going on from there leaves the old attempt in the file, on a branch the conversation no
/// longer follows. The conversation is the chain from its last message back to the start,
/// and whatever was written after that message on it.
struct ActiveChain {
    /// Records not to show: repeats of an earlier record, and attempts that were rewound.
    private(set) var hidden = Set<Int>()
    /// Where a rewound attempt that had something to read began.
    private(set) var rewoundAt = Set<Int>()

    static let treeTypes: Set<String> = ["user", "assistant", "system", "attachment"]

    init(_ records: [JSONValue], isReadable: (JSONValue) -> Bool) {
        var position: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            guard let uuid = record["uuid"]?.stringValue else { continue }
            if position[uuid] == nil { position[uuid] = index } else { hidden.insert(index) }
        }
        func inTree(_ index: Int) -> Bool {
            !hidden.contains(index) && records[index]["uuid"]?.stringValue != nil
                && Self.treeTypes.contains(records[index]["type"]?.stringValue ?? "")
        }
        func isMessage(_ index: Int) -> Bool {
            let type = records[index]["type"]?.stringValue
            return inTree(index) && (type == "user" || type == "assistant")
                && records[index]["isSidechain"]?.boolValue != true
        }
        // Compactions, recaps and the summary a compaction keeps are Claude's account of the
        // conversation, not an attempt anyone rewound.
        func isAlwaysShown(_ index: Int) -> Bool {
            records[index]["type"]?.stringValue == "system" || records[index]["isCompactSummary"]?.boolValue == true
        }
        var previousMessage = [Int?](repeating: nil, count: records.count)
        var lastMessage: Int?
        for index in records.indices {
            previousMessage[index] = lastMessage
            if isMessage(index) { lastMessage = index }
        }
        func parent(_ index: Int) -> Int? {
            let record = records[index]
            if let parent = record["parentUuid"]?.stringValue.flatMap({ position[$0] }) { return parent }
            // A compaction starts a new chain but names the message it followed. Newer versions
            // name one written after it, which it can't have followed: the message before it is.
            if let logical = record["logicalParentUuid"]?.stringValue.flatMap({ position[$0] }), logical < index {
                return logical
            }
            guard record["type"]?.stringValue == "system", record["subtype"]?.stringValue == "compact_boundary"
            else { return nil }
            return previousMessage[index]
        }

        // With missing links or several starts, there is no one chain to follow: file order.
        let roots = records.indices.filter { inTree($0) && parent($0) == nil }
        guard roots.count == 1, let leaf = records.indices.last(where: isMessage) else { return }
        var kept = Set<Int>()
        var cursor: Int? = leaf
        while let index = cursor, kept.insert(index).inserted { cursor = parent(index) }
        guard kept.contains(roots[0]) else { return }

        // Parallel tool calls leave the other parts of a reply, and their results, beside the
        // chain rather than on it.
        var messageIDs = Set<String>()
        var toolIDs = Set<String>()
        func absorb(_ record: JSONValue) {
            guard record["type"]?.stringValue == "assistant", let message = record["message"] else { return }
            if let id = message["id"]?.stringValue { messageIDs.insert(id) }
            for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                if let id = block["id"]?.stringValue { toolIDs.insert(id) }
            }
        }
        func isSibling(_ record: JSONValue) -> Bool {
            switch record["type"]?.stringValue {
            case "assistant":
                return record["message"]?["id"]?.stringValue.map(messageIDs.contains) ?? false
            case "user":
                let results = (record["message"]?["content"]?.arrayValue ?? [])
                    .filter { $0["type"]?.stringValue == "tool_result" }
                return !results.isEmpty && results.allSatisfy { $0["tool_use_id"]?.stringValue.map(toolIDs.contains) ?? false }
            default:
                return false
            }
        }
        for index in kept { absorb(records[index]) }
        var changed = true
        while changed {
            changed = false
            for index in records.indices where inTree(index) && !kept.contains(index) && isSibling(records[index]) {
                kept.insert(index)
                absorb(records[index])
                changed = true
            }
        }
        // What was written on the chain after its last message, such as a recap, is still on it.
        for index in records.indices where index > leaf && inTree(index) && !kept.contains(index) {
            if let parent = parent(index), kept.contains(parent) { kept.insert(index) }
        }

        var children: [Int: [Int]] = [:]
        var dropped: [Int] = []
        for index in records.indices where inTree(index) && !kept.contains(index) && !isAlwaysShown(index) {
            dropped.append(index)
            if let parent = parent(index) { children[parent, default: []].append(index) }
        }
        hidden.formUnion(dropped)
        for index in dropped {
            guard let parent = parent(index), kept.contains(parent) else { continue }
            var stack = [index]
            while let next = stack.popLast() {
                if records[next]["isSidechain"]?.boolValue != true, isReadable(records[next]) {
                    rewoundAt.insert(index)
                    break
                }
                stack.append(contentsOf: children[next] ?? [])
            }
        }
    }
}
