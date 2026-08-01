import Foundation

public enum MetadataDocumentError: Error, CustomStringConvertible {
    case unreadable(url: URL, reason: String)
    case notAnObject(url: URL)
    case temporaryFileFailed(directory: URL, reason: String)
    case renameFailed(from: URL, to: URL, errno: Int32)

    public var description: String {
        switch self {
        case .unreadable(let url, let reason):
            return "cannot read session metadata at \(url.path): \(reason)"
        case .notAnObject(let url):
            return "session metadata at \(url.path) is not a JSON object"
        case .temporaryFileFailed(let directory, let reason):
            return "cannot stage a temporary file in \(directory.path): \(reason)"
        case .renameFailed(let from, let to, let code):
            return "rename(\(from.lastPathComponent) -> \(to.lastPathComponent)) failed: "
                + "\(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// A read/modify/write view of one `local_<uuid>.json`.
///
/// The document keeps the entire parsed tree, not a fixed set of fields. Session metadata
/// gains keys with every Claude Desktop release — `memoryGuidelinesTemplate`, `spaceId`,
/// and `cuGrantFlags` all postdate keys that have been there since the beginning — and a
/// rewrite that drops the ones this package does not model would silently degrade the
/// session. Typed accessors below read and write *through* to ``root``; everything they do
/// not name survives untouched.
///
/// Every accessor is a no-op when ``root`` is not a JSON object; construct through
/// ``init(contentsOf:)``, which rejects that case up front.
public struct MetadataDocument: Sendable {
    public var root: JSONValue

    public init(root: JSONValue) {
        self.root = root
    }

    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MetadataDocumentError.unreadable(url: url, reason: "\(error)")
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw MetadataDocumentError.unreadable(url: url, reason: "\(error)")
        }
        guard case .object = parsed else {
            throw MetadataDocumentError.notAnObject(url: url)
        }
        self.root = parsed
    }

    // MARK: - Identity

    public var sessionId: String? {
        get { string("sessionId") }
        set { setString("sessionId", newValue) }
    }

    /// The transcript's own UUID, which names `<cliSessionId>.jsonl`. Deliberately distinct
    /// from ``sessionId``; conflating the two is the classic way to lose a transcript.
    public var cliSessionId: String? {
        get { string("cliSessionId") }
        set { setString("cliSessionId", newValue) }
    }

    public var processName: String? {
        get { string("processName") }
        set { setString("processName", newValue) }
    }

    public var vmProcessName: String? {
        get { string("vmProcessName") }
        set { setString("vmProcessName", newValue) }
    }

    public var cwd: String? {
        get { string("cwd") }
        set { setString("cwd", newValue) }
    }

    public var title: String? {
        get { string("title") }
        set { setString("title", newValue) }
    }

    public var model: String? {
        get { string("model") }
        set { setString("model", newValue) }
    }

    public var spaceId: String? {
        get { string("spaceId") }
        set { setString("spaceId", newValue) }
    }

    // MARK: - Timestamps

    /// Raw milliseconds since the Unix epoch, exactly as stored.
    ///
    /// ``createdAt`` is derived from this. Prefer the integer form whenever a value is being
    /// copied from one session to another: it is the on-disk representation, so it cannot
    /// drift by a millisecond through `Date`.
    public var createdAtMilliseconds: Int64? {
        get { root["createdAt"]?.intValue }
        set { root["createdAt"] = newValue.map { JSONValue.int($0) } }
    }

    public var lastActivityAtMilliseconds: Int64? {
        get { root["lastActivityAt"]?.intValue }
        set { root["lastActivityAt"] = newValue.map { JSONValue.int($0) } }
    }

    public var createdAt: Date? {
        get { Self.date(fromMilliseconds: createdAtMilliseconds) }
        set { createdAtMilliseconds = newValue.map(Self.milliseconds(from:)) }
    }

    public var lastActivityAt: Date? {
        get { Self.date(fromMilliseconds: lastActivityAtMilliseconds) }
        set { lastActivityAtMilliseconds = newValue.map(Self.milliseconds(from:)) }
    }

    /// Round-trips exactly for any millisecond value the store can hold: `Double` represents
    /// every integer below 2^53 without loss, and the rounding on the way back absorbs the
    /// sub-microsecond error `Date` introduces by rebasing onto its own reference date.
    public static func date(fromMilliseconds ms: Int64?) -> Date? {
        guard let ms else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Flags and account

    /// `nil` on sessions created before the flag existed, which is meaningfully different
    /// from `false`: those sessions predate host-loop mode entirely.
    public var hostLoopMode: Bool? {
        get { root["hostLoopMode"]?.boolValue }
        set { root["hostLoopMode"] = newValue.map { JSONValue.bool($0) } }
    }

    public var isArchived: Bool {
        root["isArchived"]?.boolValue ?? false
    }

    public var emailAddress: String? {
        get { string("emailAddress") }
        set { setString("emailAddress", newValue) }
    }

    public var accountName: String? {
        get { string("accountName") }
        set { setString("accountName", newValue) }
    }

    public var initialMessage: String? {
        get { string("initialMessage") }
        set { setString("initialMessage", newValue) }
    }

    public var userSelectedFolders: [String] {
        get { root["userSelectedFolders"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        set { root["userSelectedFolders"] = .array(newValue.map { JSONValue.string($0) }) }
    }

    // MARK: - Key groups

    /// Fields whose presence would carry a permissive security posture to the destination.
    ///
    /// These record decisions a person made once, in one place, about one workspace —
    /// "yes, this session may run that tool", "yes, it may reach that domain". Copying a
    /// session should not copy the consent, so a transfer drops them and the destination
    /// asks again.
    public static let securityPostureKeys: [String] = [
        "permissionMode",
        "chromePermissionMode",
        "cuAllowedApps",
        "cuGrantFlags",
        "approvedToolNames",
        "userApprovedFileAccessPaths",
        "fileDeleteApprovedMounts",
        "chromeAllowedDomains",
        "chromeTabGroupId",
    ]

    /// Fields that leak host layout or personal activity and are dropped on export.
    ///
    /// `fsDetectedFiles` in particular enumerates absolute paths from the author's machine,
    /// which is fine inside one store and is an information leak the moment the session
    /// leaves it.
    public static let privacyKeys: [String] = [
        "fsDetectedFiles",
        "mcqAnswers",
        "webFetchAllowedUrls",
        "userApprovedFileAccessPaths",
    ]

    public mutating func removeKeys(_ keys: [String]) {
        for key in keys { root[key] = nil }
    }

    // MARK: - Writing

    /// Serialize and replace `url` atomically.
    ///
    /// The staging file is created in the destination's own directory because `rename(2)`
    /// is only atomic within a filesystem, and `~/Library/Application Support` is not
    /// guaranteed to share one with the system temporary directory. A reader that opens the
    /// path at any instant sees either the whole previous file or the whole new one, which
    /// matters because Claude Desktop polls these files while it is running.
    public func write(to url: URL) throws {
        let data = root.serialized()
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
        } catch {
            throw MetadataDocumentError.temporaryFileFailed(directory: directory, reason: "\(error)")
        }

        if let existing = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = existing[.posixPermissions] as? NSNumber {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }

        let status = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return rename(source, destination)
            }
        }
        guard status == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw MetadataDocumentError.renameFailed(from: temporary, to: url, errno: code)
        }
    }

    // MARK: - Private

    private func string(_ key: String) -> String? {
        root[key]?.stringValue
    }

    private mutating func setString(_ key: String, _ value: String?) {
        root[key] = value.map { JSONValue.string($0) }
    }
}
