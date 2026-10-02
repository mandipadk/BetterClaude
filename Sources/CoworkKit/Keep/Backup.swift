import AppleArchive
import Foundation
import System

/// Everything Better Claude keeps that can't be rebuilt — kept conversations, saved file
/// versions and plans, imported claude.ai conversations, receipts, and who may read what —
/// in one password-encrypted archive.
///
/// The archive is Apple Encrypted Archive, the format macOS itself uses, so it opens without
/// Better Claude too (`aea decrypt`). The password is never stored; without it the backup
/// can't be read by anyone, including you.
public enum Backup {

    /// Apple's password-based encryption turns shorter passwords away.
    public static let minimumPasswordLength = 20

    /// What goes in, by folder or file within Better Claude's own folder. The index isn't
    /// here: it's rebuilt from Claude's files and the kept copies. Nor is `Backups`: its
    /// copies of Claude's settings carry the `env` values MCP servers are given, API keys
    /// among them, and a backup is a file people put in iCloud.
    static let included = ["Kept", "Imports", "receipts", "Recall", "Restores"]

    /// Copies of a Desktop config set aside before a change. Left out for the same reason.
    static let excludedNames: Set<String> = ["claude_desktop_config.json"]

    public enum Failure: Error, CustomStringConvertible {
        case passwordTooShort
        case wrongPasswordOrDamaged
        case couldNotWrite(String)

        public var description: String {
            switch self {
            case .passwordTooShort:
                return "The password needs at least \(Backup.minimumPasswordLength) characters. A few words together works well."
            case .wrongPasswordOrDamaged:
                return "That password doesn't open this backup, or the file is damaged."
            case .couldNotWrite(let why):
                return "Couldn't write the backup: \(why)"
            }
        }
    }

    public struct Report: Sendable, Equatable {
        public var files = 0
        public var bytes: Int64 = 0
    }

    /// iCloud Drive's folder for these, when iCloud Drive is on.
    public static func iCloudFolder(paths: HostPaths = .current) -> URL? {
        let drive = paths.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard Discovery.isDirectory(drive) else { return nil }
        return drive.appendingPathComponent("Better Claude Backups", isDirectory: true)
    }

    public static func suggestedName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Better Claude \(formatter.string(from: date)).aea"
    }

    /// Writes the backup to `destination`, replacing it only once the new one is complete.
    @discardableResult
    public static func create(at destination: URL, password: String, paths: HostPaths = .current) throws -> Report {
        guard password.count >= minimumPasswordLength else { throw Failure.passwordTooShort }
        let source = paths.betterClaudeSupport
        var report = Report()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(6)).part")
        defer { try? fm.removeItem(at: partial) }

        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        do { try context.setPassword(password) } catch { throw Failure.passwordTooShort }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(partial.path), mode: .writeOnly,
                                                      options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o600)),
              let encrypted = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context),
              let encoder = ArchiveStream.encodeStream(writingTo: encrypted),
              let keys = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DAT,MOD,MTM")
        else { throw Failure.couldNotWrite("the archive couldn't be started") }

        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(source.path), keySet: keys,
                                               selectUsing: { message, path, _ in
                // Asked once per folder (prune) and once per file (exclude): anything outside
                // the included top-level items is left out.
                guard message == .searchPruneDirectory || message == .searchExclude else { return .ok }
                let components = path.components.map(\.string)
                guard let top = components.first else { return .ok }
                if let name = components.last, excludedNames.contains(name) { return .skip }
                return included.contains(top) ? .ok : .skip
            })
            try encoder.close()
            try encrypted.close()
            try file.close()
        } catch {
            try? encoder.close()
            try? encrypted.close()
            try? file.close()
            throw Failure.couldNotWrite(String(describing: error))
        }
        for top in included {
            let url = source.appendingPathComponent(top)
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let item as URL in walker {
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, !excludedNames.contains(item.lastPathComponent) else { continue }
                report.files += 1
                report.bytes += Int64(values?.fileSize ?? 0)
            }
        }
        // The new archive has to open before it takes the old one's place.
        guard opens(partial, password: password) else {
            throw Failure.couldNotWrite("the new backup couldn't be read back")
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
        return report
    }

    /// Whether `backup` decrypts with `password` and reads through to its end: every entry's
    /// header and contents, so a file damaged or cut short partway is caught, not only its start.
    static func opens(_ backup: URL, password: String) -> Bool {
        guard let input = ArchiveByteStream.fileStream(path: FilePath(backup.path), mode: .readOnly, options: [],
                                                       permissions: FilePermissions(rawValue: 0o644)),
              let context = ArchiveEncryptionContext(from: input) else { return false }
        defer { try? input.close() }
        guard (try? context.setPassword(password)) != nil,
              let decrypted = ArchiveByteStream.decryptionStream(readingFrom: input, encryptionContext: context),
              let decoder = ArchiveStream.decodeStream(readingFrom: decrypted)
        else { return false }
        defer {
            try? decoder.close()
            try? decrypted.close()
        }
        let contents = ArchiveHeader.FieldKey("DAT")
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        do {
            while let header = try decoder.readHeader() {
                guard case .blob(_, let size, _)? = header.field(forKey: contents) else { continue }
                var remaining = size
                while remaining > 0 {
                    let count = Int(min(remaining, UInt64(buffer.count)))
                    try buffer.withUnsafeMutableBytes { bytes in
                        try decoder.readBlob(key: contents, into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<count]))
                    }
                    remaining -= UInt64(count)
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Decrypts and unpacks a backup into `folder`.
    static func extract(_ backup: URL, password: String, into staging: URL) throws {
        guard let input = ArchiveByteStream.fileStream(path: FilePath(backup.path), mode: .readOnly, options: [],
                                                       permissions: FilePermissions(rawValue: 0o644)),
              let context = ArchiveEncryptionContext(from: input) else { throw Failure.wrongPasswordOrDamaged }
        defer { try? input.close() }
        do { try context.setPassword(password) } catch { throw Failure.wrongPasswordOrDamaged }
        guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: input, encryptionContext: context),
              let decoder = ArchiveStream.decodeStream(readingFrom: decrypted),
              let extractor = ArchiveStream.extractStream(extractingTo: FilePath(staging.path))
        else { throw Failure.wrongPasswordOrDamaged }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
            try extractor.close()
            try decoder.close()
            try decrypted.close()
        } catch {
            try? extractor.close()
            try? decoder.close()
            try? decrypted.close()
            throw Failure.wrongPasswordOrDamaged
        }
    }

    /// Opens a backup and adds whatever it holds that isn't here already. Nothing already on
    /// this Mac is replaced, so restoring onto a Mac in use only fills in what's missing. The
    /// two files both sides add to are merged rather than skipped: who may read what, and each
    /// kept conversation's list of copies.
    @discardableResult
    public static func restore(from backup: URL, password: String, paths: HostPaths = .current) throws -> Report {
        let fm = FileManager.default
        let target = paths.betterClaudeSupport
        let staging = target.appendingPathComponent(".restoring-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try extract(backup, password: password, into: staging)

        var report = Report()
        guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return report }
        let base = staging.resolvingSymlinksInPath().path + "/"
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let resolved = item.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base) else { continue }
            let relative = String(resolved.dropFirst(base.count))
            guard let top = relative.split(separator: "/").first, included.contains(String(top)) else { continue }
            let destination = target.appendingPathComponent(relative)
            if fm.fileExists(atPath: destination.path) {
                if try merge(item, into: destination, relative: relative, paths: paths) {
                    report.files += 1
                    report.bytes += Int64(values?.fileSize ?? 0)
                }
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: item, to: destination)
            report.files += 1
            report.bytes += Int64(values?.fileSize ?? 0)
        }
        return report
    }

    /// Folds a file from a backup into this Mac's copy of it. Returns whether anything changed.
    static func merge(_ incoming: URL, into existing: URL, relative: String, paths: HostPaths) throws -> Bool {
        if relative == "Recall/access.json" {
            let decoder = JSONDecoder()
            guard let theirs = try? decoder.decode(RecallAccess.self, from: Data(contentsOf: incoming)),
                  let ours = try? decoder.decode(RecallAccess.self, from: Data(contentsOf: existing)) else { return false }
            // Which Desktop folder is which account is this Mac's to say; only the doors come along.
            var merged = ours
            for (consumer, others) in theirs.doors {
                for other in others { merged.setDoor(from: consumer, to: other, open: true) }
            }
            guard merged != ours else { return false }
            try merged.save(paths: paths)
            return true
        }
        if relative.hasPrefix("Kept/entries/"), relative.hasSuffix(".json") {
            guard let theirs = Vault.decodeEntry(try Data(contentsOf: incoming)),
                  let ours = Vault.decodeEntry(try Data(contentsOf: existing)),
                  theirs.key == ours.key else { return false }
            let merged = Vault.merged(ours, theirs)
            guard merged != ours else { return false }
            try AtomicWrite.write(try Vault.encodeEntry(merged), to: existing)
            return true
        }
        return false
    }
}
