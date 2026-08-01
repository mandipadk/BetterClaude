import Foundation
import CryptoKit

/// How much of the originating identity survives an export.
public enum RedactionProfile: String, Codable, Sendable, CaseIterable {
    /// Moving between installs owned by the same person: identity fields are kept, because
    /// the importer will match them against the destination account.
    case sameUser
    /// A different account: identity is stripped, the chat itself is kept intact.
    case crossUser
    /// Maximum redaction, for a transcript that will be published.
    case share
}

/// The index of a `.coworkbundle`.
///
/// This is the one type in the package modelled with `Codable`, and that is safe precisely
/// because it is *our* format: unlike Cowork metadata and Claude Code transcripts, nothing
/// else writes it, so there are no unknown keys to preserve. Forward compatibility is
/// handled by refusing to read a bundle whose ``bundleVersion`` exceeds
/// ``currentVersion`` rather than by tolerating missing fields.
public struct Manifest: Codable, Sendable {
    public static let currentVersion = 1

    /// Bump alongside the package version; it is recorded verbatim in every bundle and is
    /// the only forensic trail back to the code that produced one.
    public static let defaultProducer = "BetterClaude/0.1.0"

    public var bundleVersion: Int
    public var createdAt: Date
    public var producer: String
    public var redactionProfile: RedactionProfile
    public var sessions: [SessionEntry]
    public var warnings: [String]

    public init(bundleVersion: Int = Manifest.currentVersion,
                createdAt: Date,
                producer: String = Manifest.defaultProducer,
                redactionProfile: RedactionProfile,
                sessions: [SessionEntry],
                warnings: [String]) {
        self.bundleVersion = bundleVersion
        self.createdAt = createdAt
        self.producer = producer
        self.redactionProfile = redactionProfile
        self.sessions = sessions
        self.warnings = warnings
    }

    public struct SessionEntry: Codable, Sendable {
        /// `s0`, `s1`, … — deliberately not a session id and never a path fragment taken
        /// from the source, so that nothing about the origin leaks through the directory
        /// layout and no source-controlled string can steer a write.
        public var slot: String
        public var origin: Origin
        public var chat: ChatSummary
        /// Every regular file in the slot, relative to the slot directory, sorted.
        public var files: [FileEntry]
        public var pathMap: PathMap

        public init(slot: String, origin: Origin, chat: ChatSummary,
                    files: [FileEntry], pathMap: PathMap) {
            self.slot = slot
            self.origin = origin
            self.chat = chat
            self.files = files
            self.pathMap = pathMap
        }
    }

    /// Where the slot came from. Every field is descriptive; none of it is trusted on
    /// import, where the destination decides the real ids and paths.
    public struct Origin: Codable, Sendable {
        /// `"cowork"` or `"claudeCode"`.
        public var kind: String
        public var variantDirName: String?
        public var sessionId: String?
        public var cliSessionId: String?
        public var processName: String?
        public var cwd: String?
        public var hostLoopMode: Bool?
        public var model: String?
        public var createdAt: Date?
        public var lastActivityAt: Date?
        public var gitBranchOriginal: String?
        public var entrypointsSeen: [String]

        public init(kind: String, variantDirName: String? = nil, sessionId: String? = nil,
                    cliSessionId: String? = nil, processName: String? = nil, cwd: String? = nil,
                    hostLoopMode: Bool? = nil, model: String? = nil, createdAt: Date? = nil,
                    lastActivityAt: Date? = nil, gitBranchOriginal: String? = nil,
                    entrypointsSeen: [String] = []) {
            self.kind = kind
            self.variantDirName = variantDirName
            self.sessionId = sessionId
            self.cliSessionId = cliSessionId
            self.processName = processName
            self.cwd = cwd
            self.hostLoopMode = hostLoopMode
            self.model = model
            self.createdAt = createdAt
            self.lastActivityAt = lastActivityAt
            self.gitBranchOriginal = gitBranchOriginal
            self.entrypointsSeen = entrypointsSeen
        }

        public static let kindCowork = "cowork"
        public static let kindClaudeCode = "claudeCode"
    }

    /// Counts computed at export time, so an importer can show the user what is in a bundle
    /// without parsing a 20 MB transcript first.
    public struct ChatSummary: Codable, Sendable {
        public var title: String
        /// How the title was obtained, e.g. `metadata`, `firstUserMessage`, `filename`.
        public var titleSource: String
        public var recordCount: Int
        /// Records reachable by walking `parentUuid` from the leaf; the rest are branches
        /// the user abandoned and are not counted as conversation.
        public var chainRecordCount: Int
        public var userTurns: Int
        public var assistantTurns: Int
        public var orphanParentUuids: Int
        public var inlineMediaBlocks: Int
        public var inlineMediaBytes: Int
        public var firstTimestamp: Date?
        public var lastTimestamp: Date?

        public init(title: String, titleSource: String, recordCount: Int, chainRecordCount: Int,
                    userTurns: Int, assistantTurns: Int, orphanParentUuids: Int,
                    inlineMediaBlocks: Int, inlineMediaBytes: Int,
                    firstTimestamp: Date?, lastTimestamp: Date?) {
            self.title = title
            self.titleSource = titleSource
            self.recordCount = recordCount
            self.chainRecordCount = chainRecordCount
            self.userTurns = userTurns
            self.assistantTurns = assistantTurns
            self.orphanParentUuids = orphanParentUuids
            self.inlineMediaBlocks = inlineMediaBlocks
            self.inlineMediaBytes = inlineMediaBytes
            self.firstTimestamp = firstTimestamp
            self.lastTimestamp = lastTimestamp
        }
    }

    /// The absolute strings the transcript is full of, recorded so the importer can rewrite
    /// them to the destination's equivalents. ``occurrences`` is captured at export time so
    /// a rewrite that finds a different number of hits can be reported as a discrepancy
    /// rather than silently succeeding.
    public struct PathMap: Codable, Sendable {
        public var workspaceRoot: String?
        /// `/sessions/<processName>` — the in-VM path a non-host-loop session runs under.
        public var vmSessionPath: String?
        public var occurrences: [String: Int]

        public init(workspaceRoot: String?, vmSessionPath: String?, occurrences: [String: Int]) {
            self.workspaceRoot = workspaceRoot
            self.vmSessionPath = vmSessionPath
            self.occurrences = occurrences
        }
    }

    public struct FileEntry: Codable, Sendable {
        /// Slot-relative, `/`-separated, never absolute and never containing `..`.
        public var path: String
        public var sha256: String
        public var bytes: Int

        public init(path: String, sha256: String, bytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Layout

/// Names inside a `.coworkbundle`. A bundle is a plain directory with a known extension
/// rather than an archive: there is no external dependency to vendor, `ls` works on it, and
/// the entire zip-slip attack class simply does not exist because nothing is ever extracted.
public enum BundleLayout {
    public static let pathExtension = "coworkbundle"
    public static let manifestFileName = "manifest.json"
    public static let scanReportFileName = "scan-report.json"
    public static let sessionsDirName = "sessions"
    public static let metadataFileName = "metadata.json"
    public static let transcriptFileName = "transcript.jsonl"
    public static let subagentsDirName = "subagents"

    public static func slotName(_ index: Int) -> String { "s\(index)" }

    /// Slot names are generated, so anything that does not match exactly is either a
    /// hand-edited bundle or an attempt to smuggle a path.
    public static func isValidSlotName(_ s: String) -> Bool {
        guard s.count >= 2, s.hasPrefix("s") else { return false }
        return s.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Errors

public enum BundleError: Error, CustomStringConvertible {
    case badExtension(URL)
    case destinationExists(URL)
    case unsafeRelativePath(String)
    case reservedRelativePath(String)
    case duplicateRelativePath(String)
    case notARegularFile(URL)
    case missingManifest(URL)
    case unsupportedVersion(found: Int, supported: Int)
    case blockedByScan(ScanReport)
    case notADirectory(URL)

    public var description: String {
        switch self {
        case .badExtension(let url):
            return "\(url.lastPathComponent) is not a .\(BundleLayout.pathExtension) directory"
        case .destinationExists(let url):
            return "refusing to overwrite existing \(url.path)"
        case .unsafeRelativePath(let p):
            return "unsafe relative path in bundle: \(p)"
        case .reservedRelativePath(let p):
            return "relative path \(p) collides with a reserved slot file"
        case .duplicateRelativePath(let p):
            return "relative path \(p) supplied twice for one slot"
        case .notARegularFile(let url):
            return "\(url.path) is not a regular file (symlinks and devices are never copied into a bundle)"
        case .missingManifest(let url):
            return "no \(BundleLayout.manifestFileName) in \(url.path)"
        case .unsupportedVersion(let found, let supported):
            return "bundle version \(found) is newer than this build understands (\(supported))"
        case .blockedByScan(let report):
            let blocked = report.findings.filter { $0.tier == Scanner.Rule.Tier.block.rawValue }.count
            return "secret scan blocked the export: \(blocked) high-confidence finding(s), "
                 + "\(report.unreadable.count) unreadable file(s)"
        case .notADirectory(let url):
            return "\(url.path) is not a directory"
        }
    }
}

// MARK: - Filesystem support

/// Shared, deliberately dumb filesystem primitives used by the writer, the reader and the
/// scanner. They exist in one place so that the three agree exactly on what counts as a
/// file, what counts as a safe relative path, and what a digest is computed over.
enum BundleFS {

    struct WalkResult {
        /// Slash-separated paths relative to the walk root, sorted.
        var files: [String] = []
        var symlinks: [String] = []
        /// Sockets, fifos, devices — anything that is neither a directory nor a regular file.
        var irregular: [String] = []
        /// Directories whose contents could not be listed.
        var unreadable: [String] = []
    }

    /// Depth-first walk that **includes dotfiles**.
    ///
    /// `FileManager` only skips hidden entries when `.skipsHiddenFiles` is passed, and it is
    /// deliberately not passed here: the ripgrep-family default of ignoring dotted
    /// directories would skip every `.claude/` tree, which is exactly where credential
    /// files live.
    static func walk(_ root: URL) throws -> WalkResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BundleError.notADirectory(root)
        }
        let base = root.standardizedFileURL
        var basePath = base.path
        if !basePath.hasSuffix("/") { basePath += "/" }

        var result = WalkResult()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                result.unreadable.append(Self.relative(url, basePath: basePath))
                return true
            })
        guard let enumerator else { throw BundleError.notADirectory(root) }

        for case let url as URL in enumerator {
            let rel = relative(url, basePath: basePath)
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                result.unreadable.append(rel)
                continue
            }
            if values.isSymbolicLink == true {
                result.symlinks.append(rel)
            } else if values.isDirectory == true {
                continue
            } else if values.isRegularFile == true {
                result.files.append(rel)
            } else {
                result.irregular.append(rel)
            }
        }
        result.files.sort()
        result.symlinks.sort()
        result.irregular.sort()
        result.unreadable.sort()
        return result
    }

    private static func relative(_ url: URL, basePath: String) -> String {
        let p = url.standardizedFileURL.path
        if p.hasPrefix(basePath) { return String(p.dropFirst(basePath.count)) }
        return p
    }

    /// Streaming SHA-256, so a 21 MB transcript never lands in memory twice.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func byteCount(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    /// A relative path is safe only if it is non-empty, not absolute, has no empty, `.` or
    /// `..` component, and contains no NUL. Rejecting rather than normalising is
    /// intentional — a bundle we wrote never needs normalising, so anything that does is
    /// hostile or corrupt.
    static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains("\0") else { return false }
        for component in p.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// True when `url` resolves to `base` or something beneath it. Symlinks are resolved
    /// first specifically so that a link pointing out of the bundle fails this test.
    ///
    /// Resolution goes through ``PathEncoder/resolvedPath(_:)`` rather than
    /// `resolvingSymlinksInPath` because the latter only strips a leading `/private` when
    /// the result happens to exist — so an existing base and a not-yet-created child under
    /// it resolve to two different spellings of the same directory and containment
    /// spuriously fails.
    static func isContained(_ url: URL, in base: URL) -> Bool {
        let b = PathEncoder.resolvedPath(base.standardizedFileURL.path)
        let c = PathEncoder.resolvedPath(url.standardizedFileURL.path)
        if c == b { return true }
        return c.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// A regular file with more than one link is a hardlink to something outside the
    /// bundle, which would make the bundle's contents mutable from elsewhere.
    static func hardLinkCount(of url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.referenceCount] as? Int) ?? 1
    }
}
