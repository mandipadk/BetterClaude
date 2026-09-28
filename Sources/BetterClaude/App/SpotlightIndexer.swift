import CoreSpotlight
import CoworkKit
import Foundation
import UniformTypeIdentifiers

/// Puts every conversation in Spotlight: its title, where it happened, and what you first
/// asked. Choosing one opens it in Better Claude.
///
/// Only that much goes to Spotlight, never whole conversations; searching inside messages is
/// what Better Claude's own search is for.
@MainActor
final class SpotlightIndexer {
    static let enabledKey = "showInSpotlight"
    static let domain = "conversations"

    private var indexed: [String: String] = [:]
    private var task: Task<Void, Never>?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func update(snapshot: CatalogSnapshot, index: HistoryIndex?) {
        // A sample Mac is for screenshots and tests; it never reaches the real Spotlight.
        guard !snapshot.paths.isFixture, CSSearchableIndex.isIndexingAvailable() else { return }
        guard Self.isEnabled else {
            if !indexed.isEmpty || task == nil { clear() }
            return
        }
        task?.cancel()
        let previous = indexed
        task = Task {
            let firsts = await Self.firstPrompts(index)
            guard !Task.isCancelled else { return }
            var current: [String: String] = [:]
            var items: [CSSearchableItem] = []
            for conversation in snapshot.conversations where !conversation.isArchived {
                let install = snapshot.install(conversation.installID)?.name ?? "Claude"
                let first = firsts[conversation.id]
                let fingerprint = "\(conversation.title)|\(conversation.lastActivity.timeIntervalSince1970)|\(first ?? "")"
                current[conversation.id] = fingerprint
                guard previous[conversation.id] != fingerprint else { continue }
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = conversation.title
                attributes.displayName = conversation.title
                let place = conversation.projectName.map { "\(install), in \($0)" } ?? install
                attributes.contentDescription = first.map { "\(place): \($0)" } ?? place
                attributes.keywords = ["Claude", install] + [conversation.projectName].compactMap { $0 }
                attributes.contentModificationDate = conversation.lastActivity
                attributes.lastUsedDate = conversation.lastActivity
                items.append(CSSearchableItem(uniqueIdentifier: conversation.id, domainIdentifier: Self.domain,
                                              attributeSet: attributes))
            }
            let gone = previous.keys.filter { current[$0] == nil }
            let searchable = CSSearchableIndex.default()
            if previous.isEmpty { try? await searchable.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
            if !gone.isEmpty { try? await searchable.deleteSearchableItems(withIdentifiers: Array(gone)) }
            if !items.isEmpty { try? await searchable.indexSearchableItems(items) }
            indexed = current
        }
    }

    func clear() {
        task?.cancel()
        indexed = [:]
        task = Task { try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
    }

    /// The first thing asked in each conversation, trimmed for a one-line description.
    private static func firstPrompts(_ index: HistoryIndex?) async -> [String: String] {
        guard let index, let rows = try? await index.rows("""
            SELECT conversation_id, text FROM messages m
            WHERE role = 'user' AND kind = 'message' AND ordinal = (
                SELECT MIN(ordinal) FROM messages WHERE conversation_id = m.conversation_id
                AND role = 'user' AND kind = 'message')
            """) else { return [:] }
        var out: [String: String] = [:]
        for row in rows {
            guard let id = row.text(0), let text = row.text(1) else { continue }
            let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            out[id] = line.count > 240 ? String(line.prefix(240)) + "…" : line
        }
        return out
    }
}
