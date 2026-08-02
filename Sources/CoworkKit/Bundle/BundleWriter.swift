import Foundation

/// Assembles a `.coworkbundle`.
public enum BundleWriter {

    /// Everything needed to lay down one slot. The caller has already done the reading,
    /// summarising and content redaction; the writer's job is placement, hashing and the
    /// final safety check.
    public struct SlotInput: Sendable {
        public var origin: Manifest.Origin
        public var chat: Manifest.ChatSummary
        public var pathMap: Manifest.PathMap
        /// Cowork session metadata. `nil` for a Claude Code source, which has none.
        public var metadata: JSONValue?
        public var transcript: Data
        /// Extra content copied into the slot, e.g. `subagents`, `memory`, `uploads`,
        /// `outputs`. A directory source is copied recursively under `relativePath`.
        public var extraFiles: [(relativePath: String, source: URL)]
        /// The Project this conversation belongs to, when one travels with it.
        public var space: SpaceRef?

        public init(origin: Manifest.Origin,
                    chat: Manifest.ChatSummary,
                    pathMap: Manifest.PathMap,
                    metadata: JSONValue?,
                    transcript: Data,
                    extraFiles: [(relativePath: String, source: URL)] = [],
                    space: SpaceRef? = nil) {
            self.origin = origin
            self.chat = chat
            self.pathMap = pathMap
            self.metadata = metadata
            self.transcript = transcript
            self.extraFiles = extraFiles
            self.space = space
        }
    }

    /// Assembles into a staging directory, scans the **assembled** tree, and only then moves
    /// it into place.
    ///
    /// Scanning the sources instead would test the wrong thing: a redaction step that failed
    /// to run, or ran on the wrong copy, would still be reported clean. Scanning what will
    /// actually be handed over is the only check that can catch that, and it is why the
    /// staging directory exists at all — a blocked scan leaves nothing behind.
    ///
    /// The returned manifest is byte-identical to the one written. Scan results are *not*
    /// folded into ``Manifest/warnings``; they live in `scan-report.json`, so that the
    /// manifest that was hashed and the manifest that was scanned are the same file.
    @discardableResult
    public static func write(slots: [SlotInput],
                             to url: URL,
                             profile: RedactionProfile,
                             warnings: [String],
                             producer: String = Manifest.defaultProducer) throws -> Manifest {
        guard url.pathExtension == BundleLayout.pathExtension else {
            throw BundleError.badExtension(url)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BundleError.destinationExists(url)
        }

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(url.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)

        var cleanUpStaging = true
        defer { if cleanUpStaging { try? fm.removeItem(at: staging) } }

        let sessionsDir = staging.appendingPathComponent(BundleLayout.sessionsDirName, isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: false)

        var entries: [Manifest.SessionEntry] = []
        for (index, slot) in slots.enumerated() {
            let name = BundleLayout.slotName(index)
            let slotDir = sessionsDir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: slotDir, withIntermediateDirectories: false)

            if let metadata = slot.metadata {
                let redacted = redactIdentity(metadata, profile: profile)
                try redacted.serialized().write(
                    to: slotDir.appendingPathComponent(BundleLayout.metadataFileName), options: .atomic)
            }
            try slot.transcript.write(
                to: slotDir.appendingPathComponent(BundleLayout.transcriptFileName), options: .atomic)

            var seen: Set<String> = [BundleLayout.metadataFileName, BundleLayout.transcriptFileName]
            for extra in slot.extraFiles {
                guard BundleFS.isSafeRelativePath(extra.relativePath) else {
                    throw BundleError.unsafeRelativePath(extra.relativePath)
                }
                guard !seen.contains(extra.relativePath) else {
                    throw BundleError.duplicateRelativePath(extra.relativePath)
                }
                seen.insert(extra.relativePath)
                let destination = slotDir.appendingPathComponent(extra.relativePath)
                guard BundleFS.isContained(destination.deletingLastPathComponent(), in: slotDir)
                        || destination.deletingLastPathComponent().path == slotDir.path else {
                    throw BundleError.unsafeRelativePath(extra.relativePath)
                }
                try copy(from: extra.source, to: destination)
            }

            entries.append(Manifest.SessionEntry(
                slot: name,
                origin: slot.origin,
                chat: slot.chat,
                files: try fileEntries(in: slotDir),
                pathMap: slot.pathMap,
                space: slot.space))
        }

        let manifest = Manifest(createdAt: Date(), producer: producer,
                                redactionProfile: profile, sessions: entries, warnings: warnings)
        try Manifest.makeEncoder().encode(manifest).write(
            to: staging.appendingPathComponent(BundleLayout.manifestFileName), options: .atomic)

        let report = try Scanner.scan(root: staging)
        try Manifest.makeEncoder().encode(report).write(
            to: staging.appendingPathComponent(BundleLayout.scanReportFileName), options: .atomic)
        guard report.status != .block else { throw BundleError.blockedByScan(report) }

        try fm.moveItem(at: staging, to: url)
        cleanUpStaging = false
        return manifest
    }

    // MARK: - Copying

    /// Copies file *contents*, never the directory entry. `FileManager.copyItem` would
    /// happily reproduce a symlink, which would then point at something outside the bundle
    /// — invisible to the scanner and live at import time.
    private static func copy(from source: URL, to destination: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try source.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true { throw BundleError.notARegularFile(source) }

        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let walk = try BundleFS.walk(source)
            guard walk.symlinks.isEmpty, walk.irregular.isEmpty else {
                throw BundleError.notARegularFile(
                    source.appendingPathComponent((walk.symlinks + walk.irregular)[0]))
            }
            for rel in walk.files {
                let child = destination.appendingPathComponent(rel)
                try FileManager.default.createDirectory(
                    at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyRegularFile(from: source.appendingPathComponent(rel), to: child)
            }
            return
        }

        guard values.isRegularFile == true else { throw BundleError.notARegularFile(source) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyRegularFile(from: source, to: destination)
    }

    private static func copyRegularFile(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private static func fileEntries(in slotDir: URL) throws -> [Manifest.FileEntry] {
        let walk = try BundleFS.walk(slotDir)
        guard walk.symlinks.isEmpty, walk.irregular.isEmpty, walk.unreadable.isEmpty else {
            throw BundleError.notARegularFile(
                slotDir.appendingPathComponent(
                    (walk.symlinks + walk.irregular + walk.unreadable)[0]))
        }
        return try walk.files.map { rel in
            let url = slotDir.appendingPathComponent(rel)
            return Manifest.FileEntry(path: rel,
                                      sha256: try BundleFS.sha256Hex(of: url),
                                      bytes: try BundleFS.byteCount(of: url))
        }
    }

    // MARK: - Identity sweep

    /// Well-known identity keys, removed from session metadata for every profile except
    /// ``RedactionProfile/sameUser``.
    ///
    /// This is a backstop, not the redaction step: content redaction happens before the
    /// slot reaches the writer, and the post-assembly scan is what proves it worked. The
    /// sweep is idempotent, so running it after a fuller redactor changes nothing.
    static let identityKeys: Set<String> = [
        "emailAddress", "email", "accountName", "accountUuid", "accountId", "account_id",
        "organizationUuid", "organizationName", "orgId", "org_id", "userId", "user_id",
        "displayName", "fullName", "avatarUrl", "oauthAccount",
    ]

    static func redactIdentity(_ value: JSONValue, profile: RedactionProfile) -> JSONValue {
        guard profile != .sameUser else { return value }
        switch value {
        case .object(let object):
            var out = JSONObject()
            for pair in object.orderedPairs where !identityKeys.contains(pair.key) {
                out[pair.key] = redactIdentity(pair.value, profile: profile)
            }
            return .object(out)
        case .array(let items):
            return .array(items.map { redactIdentity($0, profile: profile) })
        default:
            return value
        }
    }
}
