import Foundation

/// A Cowork **Space** — what the Claude Desktop UI calls a Project.
///
/// A space is the second of two ways a conversation is attached to folders on disk. The first
/// is `userSelectedFolders` on the session itself; this is the other, and it is the one that
/// survives across conversations: a session carries a `spaceId`, and the space it names owns
/// the folder list.
///
/// Spaces live per organisation, in `<account>/<org>/spaces.json`. Two organisations never
/// share a space id — which is exactly why moving a conversation between installs used to
/// break its folder connection. The `spaceId` travelled, the space did not, and Claude Desktop
/// reported the project folder as no longer connected.
public struct SpaceRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Absolute host paths. Meaningful on the machine that wrote them and nowhere else.
    public var folders: [String]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, folders: [String],
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.folders = folders
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Reads and merges `spaces.json`.
///
/// Writing follows the same create-only rule as the rest of the importer: an existing space is
/// never rewritten, and unknown keys in the file — `projects`, `links`, and whatever a later
/// Claude release adds — are preserved untouched, because this format accretes keys exactly
/// like the session format does.
public enum SpaceStore {

    public static func url(inOrg orgRoot: URL) -> URL {
        orgRoot.appendingPathComponent("spaces.json")
    }

    /// Every space defined for an organisation. A missing or unreadable file is an empty list,
    /// never an error: a store with no projects is the normal case.
    public static func spaces(inOrg orgRoot: URL) -> [SpaceRef] {
        guard let document = try? document(inOrg: orgRoot) else { return [] }
        return (document["spaces"]?.arrayValue ?? []).compactMap(space(from:))
    }

    static func document(inOrg orgRoot: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url(inOrg: orgRoot))
        return try JSONValue.parse(data)
    }

    static func space(from value: JSONValue) -> SpaceRef? {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        let folders = (value["folders"]?.arrayValue ?? [])
            .compactMap { $0["path"]?.stringValue }
        return SpaceRef(id: id,
                        name: value["name"]?.stringValue ?? "",
                        folders: folders,
                        createdAt: value["createdAt"]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                        updatedAt: value["updatedAt"]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    /// How an incoming space resolves against the destination's existing ones.
    public enum Match: Sendable, Equatable {
        /// The same space id is already there. Nothing to write.
        case sameId(SpaceRef)
        /// A different id, but the same name and folders — the same project by any useful
        /// definition, usually because it was carried across in an earlier transfer. The
        /// session's `spaceId` is rewritten to point at it rather than creating a duplicate
        /// project with an identical name.
        case equivalent(SpaceRef)
        /// Nothing like it exists; it would have to be created.
        case absent
    }

    public static func match(_ incoming: SpaceRef, against existing: [SpaceRef]) -> Match {
        if let exact = existing.first(where: { $0.id == incoming.id }) { return .sameId(exact) }
        let wanted = Set(incoming.folders)
        if let twin = existing.first(where: {
            $0.name == incoming.name && Set($0.folders) == wanted
        }) { return .equivalent(twin) }
        return .absent
    }

    /// Add a space to an organisation, leaving every existing entry byte-for-byte alone.
    ///
    /// Returns `false` when a space with that id is already present, so a repeated import is a
    /// no-op rather than a duplicate.
    @discardableResult
    public static func add(_ space: SpaceRef, toOrg orgRoot: URL) throws -> Bool {
        var root = (try? document(inOrg: orgRoot)) ?? .object(JSONObject())
        if root.objectValue == nil { root = .object(JSONObject()) }
        var list = root["spaces"]?.arrayValue ?? []
        guard !list.contains(where: { $0["id"]?.stringValue == space.id }) else { return false }

        let created = Int64((space.createdAt ?? Date()).timeIntervalSince1970 * 1000)
        let updated = space.updatedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? created
        let folders: [JSONValue] = space.folders.map { path in
            .object(JSONObject([("path", .string(path))]))
        }
        let entry = JSONObject([
            ("id", .string(space.id)),
            ("name", .string(space.name)),
            ("folders", .array(folders)),
            // Present and empty in every space observed. Written rather than omitted so the
            // shape matches what Claude Desktop writes itself.
            ("projects", .array([])),
            ("links", .array([])),
            ("createdAt", .int(created)),
            ("updatedAt", .int(updated)),
        ])
        list.append(.object(entry))
        root["spaces"] = .array(list)
        try writeAtomically(root, to: url(inOrg: orgRoot))
        return true
    }

    /// Remove a space by id — used only by `undo`, to take back a space this tool created.
    @discardableResult
    public static func remove(id: String, fromOrg orgRoot: URL) throws -> Bool {
        guard var root = try? document(inOrg: orgRoot),
              let list = root["spaces"]?.arrayValue else { return false }
        let kept = list.filter { $0["id"]?.stringValue != id }
        guard kept.count != list.count else { return false }
        root["spaces"] = .array(kept)
        try writeAtomically(root, to: url(inOrg: orgRoot))
        return true
    }

    /// Replace the file in one step. Claude Desktop polls this path while it runs, so a reader
    /// must see either the whole old file or the whole new one and never a half-written list.
    static func writeAtomically(_ root: JSONValue, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try root.serialized().write(to: temporary, options: [.withoutOverwriting])
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // No existing file to replace: move the temporary into place instead.
            try? FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
