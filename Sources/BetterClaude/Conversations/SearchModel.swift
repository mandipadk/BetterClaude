import CoworkKit
import Foundation
import Observation

/// Keeps the on-disk history index current with the catalog.
///
/// The first pass reads every transcript once; after that each refresh reads only what
/// Claude added since, so it can run every time anything changes.
@MainActor
@Observable
final class IndexModel {
    private(set) var index: HistoryIndex?
    private(set) var progress: HistoryIndex.Progress?
    /// Whether the index has caught up at least once, so searching it finds everything.
    private(set) var isReady = false
    /// Bumped after each pass that changed something.
    private(set) var generation = 0
    private(set) var failure: String?
    /// Called after a pass that took in new messages.
    var onUpdate: (() -> Void)?

    private var updateTask: Task<Void, Never>?
    private var pending: CatalogSnapshot?
    private var isOpening = true

    /// Opening can mean copying a whole index forward from the last version, so it happens
    /// off the main thread; updates asked for meanwhile wait for it.
    init(paths: HostPaths) {
        let url = HistoryIndex.defaultURL(paths: paths)
        Task {
            let opened = await Task.detached(priority: .userInitiated) {
                Result { try HistoryIndex(url: url) }
            }.value
            isOpening = false
            switch opened {
            case .success(let index): self.index = index
            case .failure(let error): failure = String(describing: error)
            }
            if let next = pending {
                pending = nil
                update(from: next)
            }
        }
    }

    /// Catches the index up with `snapshot`. A call while a pass is running queues one more
    /// pass with the newest snapshot rather than starting another alongside it.
    func update(from snapshot: CatalogSnapshot) {
        guard let index else {
            if isOpening { pending = snapshot }
            return
        }
        if updateTask != nil {
            pending = snapshot
            return
        }
        updateTask = Task {
            let changed: Int
            do {
                changed = try await index.update(from: snapshot) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isReady || progress.total > 20 else { return }
                        self.progress = progress.done < progress.total ? progress : nil
                    }
                }
                failure = nil
            } catch {
                changed = 0
                failure = String(describing: error)
            }
            progress = nil
            isReady = true
            if changed > 0 || generation == 0 {
                generation += 1
                onUpdate?()
            }
            updateTask = nil
            if let next = pending {
                pending = nil
                update(from: next)
            }
        }
    }
}

/// Searching every message of every conversation, as you type.
@MainActor
@Observable
final class SearchModel {
    private(set) var hits: [HistorySearch.Hit] = []
    private(set) var lastQuery = ""
    /// At most this many conversations come back, the best matches first.
    static let limit = 100
    /// More conversations matched than came back.
    var isCapped: Bool { hits.count >= Self.limit }
    private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let history: IndexModel

    init(history: IndexModel) {
        self.history = history
    }

    /// Searches after a short pause, so each keystroke doesn't start its own search.
    func search(_ query: String, immediately: Bool = false) {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let index = history.index else {
            hits = []
            lastQuery = ""
            return
        }
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = (try? await index.search(needle, options: .init(limit: Self.limit))) ?? []
            guard !Task.isCancelled else { return }
            hits = found
            lastQuery = needle
            isSearching = false
        }
    }

    /// Runs the last search again, after the index took in new messages.
    func refresh() {
        guard !lastQuery.isEmpty else { return }
        search(lastQuery, immediately: true)
    }
}
