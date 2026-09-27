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
    var findQuery = ""

    private var loadTask: Task<Void, Never>?

    func open(_ conversation: ConversationRef, in install: Install?) {
        guard conversation.id != self.conversation?.id || state != .ready else { return }
        loadTask?.cancel()
        self.conversation = conversation
        self.install = install
        readable = nil
        transcript = nil
        findQuery = ""
        guard let url = conversation.transcriptURL else {
            state = .missing
            return
        }
        state = .loading
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Transcript, ReadableConversation), Error> in
                do {
                    let transcript = try Transcript(contentsOf: url)
                    return .success((transcript, ReadableConversation(transcript: transcript)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
            switch result {
            case .success(let (transcript, readable)):
                self.transcript = transcript
                self.readable = readable
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
