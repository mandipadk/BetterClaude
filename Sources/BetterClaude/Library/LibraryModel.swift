import AppKit
import CoworkKit
import Observation
import QuickLookThumbnailing

/// What the Library shows at once.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case everything, files, images, code, prompts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .files: return "Documents"
        case .images: return "Images"
        case .code: return "Code"
        case .prompts: return "Prompts"
        }
    }

    func includes(_ artifact: Artifact) -> Bool {
        switch self {
        case .everything: return true
        case .files: return [.document, .data, .other, .upload].contains(artifact.kind)
        case .images: return artifact.kind == .image
        case .code: return artifact.kind == .code
        case .prompts: return false
        }
    }
}

/// Everything Claude has made, gathered from every conversation on the Mac.
@MainActor
@Observable
final class LibraryModel {
    private(set) var summary: HarvestSummary?
    private(set) var isGathering = false
    var filter: LibraryFilter = .everything
    var query = ""
    var selectedID: String?

    /// What the last gather read, so a refresh that changed no conversation reads nothing.
    private var gatheredFingerprint: Int?
    private var lastGathered: Date?
    /// The newest snapshot asked for while a gather ran or was held back.
    private var pending: CatalogSnapshot?
    private var deferred: Task<Void, Never>?

    /// The least time between two gathers while Claude keeps writing.
    private static let spacing: TimeInterval = 30

    /// Reads every conversation's messages and files. Several hundred megabytes on a busy
    /// Mac, so it runs spread across cores, off the main actor, and only when a conversation
    /// changed: at most every half minute, with the newest snapshot once that has passed.
    func gather(from snapshot: CatalogSnapshot) {
        let fingerprint = Self.fingerprint(snapshot)
        guard fingerprint != gatheredFingerprint else { pending = nil; return }
        if isGathering {
            pending = snapshot
            return
        }
        if let last = lastGathered, Date().timeIntervalSince(last) < Self.spacing {
            pending = snapshot
            guard deferred == nil else { return }
            let wait = Self.spacing - Date().timeIntervalSince(last)
            deferred = Task {
                try? await Task.sleep(for: .seconds(wait))
                deferred = nil
                if let next = pending {
                    pending = nil
                    gather(from: next)
                }
            }
            return
        }
        isGathering = true
        let sources = snapshot.conversations.map { conversation in
            HarvestSource(conversationTitle: conversation.title,
                          conversationID: conversation.id,
                          container: conversation.projectName
                              ?? snapshot.install(conversation.installID)?.name ?? "",
                          transcriptURL: conversation.transcriptURL,
                          workspaceURL: conversation.coworkSession?.workspaceURL)
        }
        Task {
            let summary = await ArtifactHarvest.harvest(
                sources: sources, maximumConcurrency: ProcessInfo.processInfo.activeProcessorCount)
            self.summary = summary
            self.isGathering = false
            self.gatheredFingerprint = fingerprint
            self.lastGathered = Date()
            if let next = pending {
                pending = nil
                gather(from: next)
            }
        }
    }

    /// Changes whenever a conversation is added, removed, renamed or written to.
    private static func fingerprint(_ snapshot: CatalogSnapshot) -> Int {
        var hasher = Hasher()
        for conversation in snapshot.conversations {
            hasher.combine(conversation.id)
            hasher.combine(conversation.title)
            hasher.combine(conversation.bytes)
            hasher.combine(conversation.lastActivity)
            hasher.combine(conversation.projectName)
        }
        return hasher.finalize()
    }

    var visible: [Artifact] {
        guard let summary else { return [] }
        var list = summary.artifacts.filter(filter.includes)
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { list = ArtifactHarvest.search(list, query: needle) }
        return list.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var selected: Artifact? {
        selectedID.flatMap { id in summary?.artifacts.first { $0.id == id } }
    }

    func count(_ filter: LibraryFilter) -> Int {
        summary?.artifacts.filter(filter.includes).count ?? 0
    }
}

/// Thumbnails for files, made by Quick Look and kept for the session.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    static func load(_ url: URL, size: CGFloat) async -> NSImage? {
        if let hit = cached(url, size: size) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let image = thumbnail.nsImage
        cache.setObject(image, forKey: key(url, size))
        return image
    }

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)#\(Int(size))" as NSString
    }
}
