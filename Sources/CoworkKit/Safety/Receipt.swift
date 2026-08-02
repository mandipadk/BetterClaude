import CryptoKit
import Foundation

/// Which way a transfer went. Recorded so a receipt can be read back without the caller
/// having to reconstruct intent from the paths.
public enum TransferDirection: String, Codable, Sendable {
    case coworkToCowork
    case coworkToCode
    case codeToCowork
}

/// SHA-256 helpers.
///
/// Files here are transcripts and workspace payloads that can run to hundreds of megabytes,
/// so the file variant streams rather than loading the whole thing to hash it.
public enum FileDigest {
    public static func hex(_ data: Data) -> String {
        hexString(CryptoKit.SHA256.hash(data: data))
    }

    public static func hex(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.reduce(into: "") { $0 += String(format: "%02x", $1) }
    }
}

/// A record of everything one import touched, written before the import is reported as done.
///
/// `Codable` is appropriate here and nowhere else in this package: this is our own format,
/// versioned by us, so there are no unknown keys to preserve. Session metadata and
/// transcripts go through `JSONValue` for exactly the opposite reason.
public struct ImportReceipt: Codable, Sendable {
    public static let currentVersion = 1

    public let receiptVersion: Int
    public let id: String
    public let timestamp: Date
    public let direction: TransferDirection
    public let bundlePath: String?
    public let bundleSha256: String?
    /// Human-readable destination, from `Endpoint.describedDestination`.
    public let destination: String
    /// Paths this import brought into existence. Reverted deepest-first.
    public var created: [CreatedEntry]
    /// Pre-existing files this import overwrote. Empty for every normal import — the import
    /// path refuses to clobber, and a non-empty array here marks a deliberate merge.
    public var modified: [ModifiedFile]
    /// `false` until the import finishes. A receipt still `false` on next launch is the
    /// signature of a crash mid-import, and is what `Undo.incomplete()` surfaces.
    public var completed: Bool
    /// Projects this import added to the destination's `spaces.json`.
    ///
    /// Recorded separately from `created` because a space is an entry merged into a file that
    /// already existed, not a path brought into being — so undo has to remove one array
    /// element rather than delete a file. Optional so receipts written before this existed
    /// still decode.
    public var createdSpaces: [CreatedSpace]?

    /// One project added to an organisation, and where to take it back out of.
    public struct CreatedSpace: Codable, Sendable {
        public let spaceId: String
        public let orgRoot: String
        public let name: String

        public init(spaceId: String, orgRoot: String, name: String) {
            self.spaceId = spaceId
            self.orgRoot = orgRoot
            self.name = name
        }
    }

    /// One created path plus the fingerprint it had when we wrote it.
    ///
    /// The fingerprint exists so `Undo.revert` can refuse to delete a file the user has
    /// since edited. Without it, undoing a week-old import would silently destroy work.
    public struct CreatedEntry: Codable, Sendable {
        public let path: String
        public let isDirectory: Bool
        /// `nil` for directories, and for files we chose not to fingerprint. A `nil`
        /// fingerprint on a file blocks deletion rather than permitting it.
        public let sha256: String?

        public init(path: String, isDirectory: Bool, sha256: String?) {
            self.path = path
            self.isDirectory = isDirectory
            self.sha256 = sha256
        }
    }

    public struct ModifiedFile: Codable, Sendable {
        public let path: String
        public let backupPath: String
        public let sha256Before: String

        public init(path: String, backupPath: String, sha256Before: String) {
            self.path = path
            self.backupPath = backupPath
            self.sha256Before = sha256Before
        }
    }

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                direction: TransferDirection,
                bundlePath: String? = nil,
                bundleSha256: String? = nil,
                destination: String,
                created: [CreatedEntry] = [],
                modified: [ModifiedFile] = [],
                completed: Bool = false,
                createdSpaces: [CreatedSpace]? = nil) {
        self.receiptVersion = Self.currentVersion
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.bundlePath = bundlePath
        self.bundleSha256 = bundleSha256
        self.destination = destination
        self.created = created
        self.modified = modified
        self.completed = completed
        self.createdSpaces = createdSpaces
    }

    /// Fingerprint a file we just wrote and add it to `created`.
    ///
    /// Call this immediately after the write, before anything else can touch the file —
    /// a fingerprint taken later would bless someone else's change as ours.
    public mutating func recordCreatedFile(at url: URL) throws {
        created.append(CreatedEntry(
            path: url.standardizedFileURL.path,
            isDirectory: false,
            sha256: try FileDigest.hex(contentsOf: url)
        ))
    }

    public mutating func recordCreatedDirectory(at url: URL) {
        created.append(CreatedEntry(
            path: url.standardizedFileURL.path,
            isDirectory: true,
            sha256: nil
        ))
    }

    /// Record every file and directory under `root`, plus `root` itself.
    public mutating func recordCreatedTree(at root: URL) throws {
        recordCreatedDirectory(at: root)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { return }
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            if isDirectory {
                recordCreatedDirectory(at: url)
            } else {
                try recordCreatedFile(at: url)
            }
        }
    }
}
