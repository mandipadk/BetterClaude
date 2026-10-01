import Foundation

/// A Cowork project, with the conversations in it, in the one account that defines it.
///
/// A project is a space in `spaces.json`; a conversation belongs to one by the `spaceId` in its
/// metadata. Copying a project is copying those conversations together: the importer creates the
/// space once in the destination, with its folders and memory, and points each one at it.
public struct CoworkProject: Sendable, Hashable, Identifiable {
    public let space: SpaceRef
    public let account: AccountRef
    /// Newest first.
    public let sessions: [SessionRef]

    public var id: String { account.root.path + "#" + space.id }
    public var name: String { space.name.isEmpty ? "Untitled project" : space.name }

    public init(space: SpaceRef, account: AccountRef, sessions: [SessionRef]) {
        self.space = space
        self.account = account
        self.sessions = sessions
    }
}

public enum CoworkProjects {
    /// Every project that holds at least one of `sessions`, grouped by the account that defines
    /// it. A project with no conversations has nothing to carry, so it isn't listed.
    public static func projects(in sessions: [SessionRef]) -> [CoworkProject] {
        let byOrg = Dictionary(grouping: sessions) { $0.account.root.path }
        var result: [CoworkProject] = []
        for (_, members) in byOrg {
            guard let account = members.first?.account else { continue }
            let spaces = SpaceStore.spaces(inOrg: account.root)
            guard !spaces.isEmpty else { continue }
            var bySpace: [String: [SessionRef]] = [:]
            for session in members {
                guard let spaceId = spaceID(of: session) else { continue }
                bySpace[spaceId, default: []].append(session)
            }
            for space in spaces {
                guard let inside = bySpace[space.id], !inside.isEmpty else { continue }
                result.append(CoworkProject(space: space, account: account,
                                            sessions: inside.sorted { $0.lastActivityAt > $1.lastActivityAt }))
            }
        }
        return result.sorted {
            ($0.sessions.first?.lastActivityAt ?? .distantPast) > ($1.sessions.first?.lastActivityAt ?? .distantPast)
        }
    }

    /// The project a conversation belongs to, read from its metadata.
    public static func spaceID(of session: SessionRef) -> String? {
        guard let id = (try? MetadataDocument(contentsOf: session.metadataURL))?.spaceId, !id.isEmpty else { return nil }
        return id
    }
}
