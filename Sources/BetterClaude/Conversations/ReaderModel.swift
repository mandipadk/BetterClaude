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
    private(set) var transcript: Transcript?
    /// Messages a fork can start from, by message id. Empty for conversations that can't be
    /// forked in place.
    private(set) var forkPoints: [String: BranchPoint] = [:]
    var findQuery = ""

    private var loadTask: Task<Void, Never>?

    func open(_ conversation: ConversationRef, in install: Install?, force: Bool = false) {
        guard force || conversation.id != self.conversation?.id || state != .ready else { return }
        let keepFind = force ? findQuery : ""
        loadTask?.cancel()
        self.conversation = conversation
        self.install = install
        if !force {
            readable = nil
            transcript = nil
        }
        forkPoints = [:]
        findQuery = keepFind
        if let external = conversation.external {
            if !force || readable == nil { state = .loading }
            loadTask = Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try external.scan() } }.value
                guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
                switch result {
                case .success(let scan):
                    self.readable = ReadableConversation(scan: scan, model: external.model)
                    self.state = .ready
                case .failure:
                    self.state = .failed("This conversation couldn't be read.")
                }
            }
            return
        }
        guard let url = conversation.transcriptURL else {
            state = .missing
            return
        }
        if !force || readable == nil { state = .loading }
        loadTask = Task {
            // A kept copy lives in Better Claude's own folder; a fork beside it would land
            // somewhere Claude Code never looks.
            let forkable = conversation.claudeCodeSession != nil && !url.path.hasPrefix(Vault.root.path)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Transcript, ReadableConversation, [BranchPoint]), Error> in
                do {
                    let transcript = try Transcript(contentsOf: url)
                    let points = forkable ? ConversationBranch.points(in: transcript) : []
                    return .success((transcript, ReadableConversation(transcript: transcript), points))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
            switch result {
            case .success(let (transcript, readable, points)):
                self.transcript = transcript
                self.readable = readable
                self.forkPoints = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.state = .ready
            case .failure:
                self.state = .failed("This conversation couldn't be read. It may be in use or damaged.")
            }
        }
    }

    func close() {
        loadTask?.cancel()
        conversation = nil
        install = nil
        readable = nil
        transcript = nil
        state = .idle
    }

    /// Entries that match the find field; everything when it is empty. Tool work is hidden
    /// while finding, since it has no text to match.
    var visibleEntries: [ReadableConversation.Entry] {
        guard let readable else { return [] }
        let needle = findQuery.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return readable.entries }
        return readable.entries.filter { entry in
            if case .message(let message) = entry { return message.text.localizedCaseInsensitiveContains(needle) }
            return false
        }
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
        guard let transcript, let point = forkPoints[messageID] else {
            throw BranchError.pointNotFound(messageID)
        }
        let name = title.trimmingCharacters(in: .whitespaces)
        // A Code tab session forks into the same app's Code tab.
        var record: URL?
        if case .codeTab(let source, _) = conversation?.origin { record = source.metadataURL }
        return try await Task.detached(priority: .userInitiated) { [record] in
            let (plan, branch) = try ConversationBranch.plan(transcript: transcript, cutAt: point,
                                                             newTitle: name.isEmpty ? nil : name)
            _ = try ConversationBranch.write(branch, plan: plan, codeTabRecord: record)
            return plan.destinationURL
        }.value
    }

    /// Saves the conversation as Markdown where the person chooses.
    func exportMarkdown() {
        guard let transcript, let conversation else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExport.suggestedFileName(for: conversation.title)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = MarkdownExport.render(transcript: transcript, title: conversation.title,
                                             model: readable?.model.map(humanModelName) ?? "")
        try? Data(markdown.utf8).write(to: url, options: .atomic)
    }
}
