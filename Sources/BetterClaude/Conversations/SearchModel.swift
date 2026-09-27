import CoworkKit
import Foundation
import Observation

/// Searching inside every conversation's messages, not just titles.
///
/// Reading every transcript is the expensive part, so it happens once, off the main actor,
/// spread across cores, and only when someone actually searches messages.
@MainActor
@Observable
final class SearchModel {
    private(set) var hits: [SearchHit] = []
    private(set) var isIndexing = false
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var lastQuery = ""

    private var index = SearchIndex()
    private var isBuilt = false
    private var searchTask: Task<Void, Never>?

    /// Forget what was read; the next search reads again.
    func invalidate() {
        index = SearchIndex()
        isBuilt = false
        hits = []
        lastQuery = ""
    }

    func search(_ query: String, in snapshot: CatalogSnapshot) {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)
        lastQuery = needle
        guard !needle.isEmpty else { hits = []; return }
        searchTask = Task {
            if !isBuilt { await build(from: snapshot) }
            guard !Task.isCancelled else { return }
            let found = await index.search(needle)
            guard !Task.isCancelled, lastQuery == needle else { return }
            hits = found
        }
    }

    private func build(from snapshot: CatalogSnapshot) async {
        isIndexing = true
        defer { isIndexing = false }
        let sources = snapshot.conversations.compactMap { conversation -> (ConversationLocation, String, Date)? in
            guard let url = conversation.transcriptURL else { return nil }
            let install = snapshot.install(conversation.installID)
            return (ConversationLocation(kind: conversation.coworkSession == nil ? .claudeCode : .cowork,
                                         container: install?.name ?? "",
                                         identity: conversation.projectName,
                                         transcriptURL: url, rowID: conversation.id),
                    conversation.title, conversation.lastActivity)
        }
        total = sources.count
        indexed = 0

        let entries: [SearchIndex.Entry] = await withTaskGroup(of: SearchIndex.Entry?.self) { group in
            let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
            var iterator = sources.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let next = iterator.next() else { return }
                inFlight += 1
                group.addTask(priority: .userInitiated) {
                    try? SearchIndex.makeEntry(location: next.0, title: next.1, lastActivity: next.2)
                }
            }
            for _ in 0..<limit { addNext() }
            var built: [SearchIndex.Entry] = []
            while inFlight > 0, let finished = await group.next() {
                inFlight -= 1
                indexed += 1
                if let finished { built.append(finished) }
                addNext()
            }
            return built
        }
        await index.replaceAll(with: entries)
        isBuilt = true
    }
}
