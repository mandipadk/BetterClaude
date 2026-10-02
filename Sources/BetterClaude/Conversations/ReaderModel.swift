import AppKit
import CoworkKit
import Observation

/// The conversation open in the reader. Transcripts can run past 100 MB, so reading and
/// flattening one happens off the main actor; the window keeps responding meanwhile.
@MainActor
@Observable
final class ReaderModel {
    enum State: Equatable {
        case idle
        case loading
        case ready
        /// Its record survived but its messages did not.
        case missing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var conversation: ConversationRef?
    private(set) var install: Install?
    private(set) var readable: ReadableConversation?
    /// Messages a fork can start from, by message id. Empty for conversations that can't be
    /// forked in place.
    private(set) var forkPoints: [String: BranchPoint] = [:]
    var findQuery = ""
    /// The find bar, shown with ⌘F.
    var showsFind = false
    /// Bumped each time ⌘F asks for the find field, so it takes focus even when it's already showing.
    private(set) var findFocusRequest = 0
    /// What happened during the conversation, placed between its messages.
    private(set) var markers: [TimelineMarker] = []
    /// Claims Claude itself made that the transcript doesn't back, by the millisecond they
    /// were made: the index keeps times as floating-point seconds, so a `Date` read back from
    /// it rarely equals the one parsed from the transcript.
    private(set) var doubtfulClaims: [Int64: [Claims.Claim]] = [:]
    private var annotationsFor: String?
    /// The size of the transcript `readable` was read from.
    private var loadedBytes: Int64?

    /// Shows the find bar and puts the cursor in it.
    func find() {
        showsFind = true
        findFocusRequest += 1
    }

    func closeFind() {
        findQuery = ""
        showsFind = false
    }

    static func claimKey(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Claims in a reply that the transcript doesn't back.
    func claims(for message: MessageText) -> [Claims.Claim] {
        guard message.role != .user, let time = message.timestamp else { return [] }
        return doubtfulClaims[Self.claimKey(time)] ?? []
    }

    /// Who replies in the open conversation: Codex for a Codex conversation.
    var assistantName: String {
        conversation?.external?.source == .codex ? "Codex" : "Claude"
    }

    /// Loads the markers and claim checks for the open conversation from the index, once for
    /// each version of it the index has read.
    func loadAnnotations(index: HistoryIndex?) async {
        guard let conversation, let index, conversation.external == nil else {
            markers = []
            doubtfulClaims = [:]
            return
        }
        let id = conversation.id
        let indexed = (try? await index.rows("SELECT indexed_bytes FROM conversations WHERE id = ?", [.text(id)]))?
            .first?.int(0) ?? 0
        let key = "\(id)#\(indexed)"
        guard annotationsFor != key else { return }
        let record = try? await FlightRecord.load(conversationID: id, index: index)
        let switches = (try? await ModelDrift.switches(conversationID: id, index: index)) ?? []
        let runs = (try? await Subagents.runs(conversationID: id, index: index)) ?? []
        let claims = (try? await Claims.check(conversationID: id, index: index)) ?? []
        guard self.conversation?.id == id else { return }
        markers = TimelineMarkers.markers(record: record, switches: switches, runs: runs)
        var doubtful: [Int64: [Claims.Claim]] = [:]
        for claim in claims where claim.agentID == nil {
            guard let time = claim.timestamp else { continue }
            switch claim.verdict {
            case .contradicted, .noEvidence: doubtful[Self.claimKey(time), default: []].append(claim)
            default: break
            }
        }
        doubtfulClaims = doubtful
        annotationsFor = key
    }

    private var loadTask: Task<Void, Never>?

    /// Opens a conversation. `force` reads the open one again because it grew; those reads
    /// wait a moment so a conversation Claude is still writing isn't read on every line.
    func open(_ conversation: ConversationRef, in install: Install?, force: Bool = false) {
        guard force || conversation.id != self.conversation?.id || state != .ready else { return }
        let reload = force && conversation.id == self.conversation?.id
        if reload, state == .ready, conversation.bytes == loadedBytes {
            self.conversation = conversation
            self.install = install
            return
        }
        loadTask?.cancel()
        self.conversation = conversation
        self.install = install
        if !reload {
            readable = nil
            loadedBytes = nil
            forkPoints = [:]
            findQuery = ""
            showsFind = false
            markers = []
            doubtfulClaims = [:]
            annotationsFor = nil
        }
        if readable == nil { state = .loading }
        let bytes = conversation.bytes

        if let external = conversation.external {
            loadTask = Task {
                if reload { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                let work = Task.detached(priority: .userInitiated) { Result { try external.scan() } }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
                switch result {
                case .success(let scan):
                    self.readable = ReadableConversation(scan: scan, model: external.model)
                    self.loadedBytes = bytes
                    self.state = .ready
                case .failure:
                    if self.readable == nil { self.state = .failed("This conversation couldn't be read.") }
                }
            }
            return
        }
        guard let url = conversation.transcriptURL else {
            state = .missing
            return
        }
        loadTask = Task {
            if reload { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            // A kept copy lives in Better Claude's own folder; a fork beside it would land
            // somewhere Claude Code never looks.
            let forkable = conversation.claudeCodeSession != nil && !url.path.hasPrefix(Vault.root.path)
            // The parsed transcript holds every pasted image; only what the reader shows is kept.
            let work = Task.detached(priority: .userInitiated) { () -> Result<(ReadableConversation, [BranchPoint]), Error> in
                do {
                    let transcript = try Transcript(contentsOf: url)
                    try Task.checkCancellation()
                    let points = forkable ? ConversationBranch.points(in: transcript) : []
                    return .success((ReadableConversation(transcript: transcript), points))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
            switch result {
            case .success(let (readable, points)):
                self.readable = readable
                self.loadedBytes = bytes
                self.forkPoints = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.state = .ready
            case .failure:
                // A conversation already showing stays up if a later read of it fails.
                if self.readable == nil {
                    self.state = .failed("This conversation couldn't be read. It may be in use or damaged.")
                }
            }
        }
    }

    func close() {
        loadTask?.cancel()
        conversation = nil
        install = nil
        readable = nil
        loadedBytes = nil
        showsFind = false
        findQuery = ""
        state = .idle
    }

    /// Entries that match the find field; everything when it is empty. Tool work is hidden
    /// while finding, since it has no text to match.
    var visibleEntries: [ReadableConversation.Entry] {
        guard let readable else { return [] }
        let needle = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return readable.entries }
        return readable.entries.filter { entry in
            switch entry {
            case .message(let message):
                return message.text.localizedCaseInsensitiveContains(needle)
                    || message.attachments.contains { $0.localizedCaseInsensitiveContains(needle) }
            case .compaction(let compaction):
                return compaction.summary?.localizedCaseInsensitiveContains(needle) ?? false
            case .recap(_, let text, _):
                return text.localizedCaseInsensitiveContains(needle)
            case .notice(let notice):
                return notice.text.localizedCaseInsensitiveContains(needle)
            case .tools:
                return false
            }
        }
    }

    /// Whether the find field holds something to find.
    var isFinding: Bool {
        !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many messages a fork from `messageID` keeps.
    func messagesKept(upTo messageID: String) -> Int {
        guard let readable else { return 0 }
        var count = 0
        for entry in readable.entries {
            guard case .message(let message) = entry else { continue }
            count += 1
            if message.id == messageID { break }
        }
        return count
    }

    /// Forks the open conversation at a message into a new one beside it, with a receipt so
    /// it can be undone. Returns the new transcript's location.
    func fork(at messageID: String, title: String) async throws -> URL {
        guard let point = forkPoints[messageID], let url = conversation?.transcriptURL else {
            throw BranchError.pointNotFound(messageID)
        }
        let name = title.trimmingCharacters(in: .whitespaces)
        // A Code tab session forks into the same app's Code tab.
        var record: URL?
        if case .codeTab(let source, _) = conversation?.origin { record = source.metadataURL }
        return try await Task.detached(priority: .userInitiated) { [record] in
            let transcript = try Transcript(contentsOf: url)
            let (plan, branch) = try ConversationBranch.plan(transcript: transcript, cutAt: point,
                                                             newTitle: name.isEmpty ? nil : name)
            _ = try ConversationBranch.write(branch, plan: plan, codeTabRecord: record)
            return plan.destinationURL
        }.value
    }

    /// Whether the conversation can be exported: it's the one open and it has been read.
    func canExport(_ conversation: ConversationRef) -> Bool {
        conversation.id == self.conversation?.id && readable != nil
    }

    /// Saves the conversation as one self-contained web page, to send to someone.
    func exportWebPage() {
        guard let readable, let conversation else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExport.suggestedFileName(for: conversation.title)
            .replacingOccurrences(of: ".md", with: "") + ".html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let page = ConversationPage.render(readable, title: conversation.title, model: readable.model.map(humanModelName),
                                           home: HostPaths.current.home.path, assistantName: assistantName)
        save(Data(page.utf8), to: url)
    }

    /// Saves the conversation as Markdown where the person chooses.
    func exportMarkdown() {
        guard let readable, let conversation else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExport.suggestedFileName(for: conversation.title)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = MarkdownExport.render(readable, title: conversation.title,
                                             model: readable.model.map(humanModelName), assistantName: assistantName)
        save(Data(SecretSweep.redact(markdown).utf8), to: url)
    }

    private func save(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
