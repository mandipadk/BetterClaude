import Foundation

/// What a revert actually managed to do. Every path is accounted for in exactly one list.
public struct RevertResult: Sendable {
    public let deleted: [String]
    public let restored: [String]
    /// Paths deliberately left alone, each with the reason. These are reported to the user,
    /// never swallowed — a skipped entry usually means the file has since been edited, which
    /// is precisely the case where a silent partial undo would be worst.
    public let skipped: [(path: String, reason: String)]

    public init(deleted: [String], restored: [String], skipped: [(path: String, reason: String)]) {
        self.deleted = deleted
        self.restored = restored
        self.skipped = skipped
    }

    public var isClean: Bool { skipped.isEmpty }

    /// What was left behind for a reason worth telling someone: everything skipped except
    /// what was already gone.
    public var leftInPlace: [(path: String, reason: String)] {
        skipped.filter { $0.reason != Undo.alreadyAbsent }
    }
}

public enum UndoError: Error, CustomStringConvertible {
    case receiptsDirectoryUnavailable(path: String, underlying: String)
    case encodingFailed(id: String, underlying: String)
    case receiptNotFound(id: String)
    case alreadyUndone(id: String)
    /// A Claude has the store open that this would change, and could write over the undo.
    case storeInUse(pids: [pid_t])

    public var description: String {
        switch self {
        case .alreadyUndone:
            return "That change has already been undone."
        case .storeInUse:
            return "Claude is open with the conversations this would change. Quit it, then undo again."
        case .receiptNotFound(let id):
            return "no receipt \(id) was found"
        case .receiptsDirectoryUnavailable(let path, let underlying):
            return "could not open the receipts directory at \(path): \(underlying)"
        case .encodingFailed(let id, let underlying):
            return "could not encode receipt \(id): \(underlying)"
        }
    }
}

/// Durable record of imports, and the machinery to take one back.
///
/// Receipts live outside every Claude store on purpose. They are our data, they must survive
/// a user deleting a variant's store directory, and writing them anywhere under
/// `Application Support/Claude*` would put unrecognized files in a tree the app scans.
public enum Undo {

    public static var receiptsDirectory: URL {
        HostPaths.current.betterClaudeSupport
            .appendingPathComponent("receipts", isDirectory: true)
    }

    public static func save(_ receipt: ImportReceipt) throws {
        try WriteFence.check(receiptsDirectory)
        let directory = receiptsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UndoError.receiptsDirectoryUnavailable(
                path: directory.path, underlying: String(describing: error))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw UndoError.encodingFailed(id: receipt.id, underlying: String(describing: error))
        }

        try AtomicWrite.write(data, to: directory.appendingPathComponent("\(receipt.id).json"))
    }

    /// All readable receipts, newest first.
    ///
    /// A receipt that fails to decode is skipped rather than thrown: one corrupt file must
    /// not make the whole undo history unavailable, which is when the user needs it most.
    public static func receipts() throws -> [ImportReceipt] {
        let directory = receiptsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw UndoError.receiptsDirectoryUnavailable(
                path: directory.path, underlying: String(describing: error))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ImportReceipt] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let receipt = try? decoder.decode(ImportReceipt.self, from: data)
            else { continue }
            loaded.append(receipt)
        }
        return loaded.sorted { $0.timestamp > $1.timestamp }
    }

    /// Receipts whose import never reported completion — the fingerprint of a crash or a
    /// kill partway through a write.
    public static func incomplete() throws -> [ImportReceipt] {
        try receipts().filter { !$0.completed && $0.revertedAt == nil }
    }

    public static let alreadyAbsent = "already absent"

    /// Undo, and remember that it was undone so it is not offered again.
    ///
    /// Only remembered when nothing was left behind: a file kept because it changed since is
    /// still the receipt's to take back, once the person has dealt with it.
    public static func revertAndRecord(_ receipt: ImportReceipt) throws -> RevertResult {
        let current = (try? receipts().first { $0.id == receipt.id }) ?? receipt
        guard current.revertedAt == nil else { throw UndoError.alreadyUndone(id: receipt.id) }
        let result = try revert(current)
        if result.leftInPlace.isEmpty {
            var updated = current
            updated.revertedAt = Date()
            try save(updated)
        }
        return result
    }

    /// Undo an import.
    ///
    /// Created files are deleted only if their contents still match what we wrote. A file the
    /// user has edited since is left in place and reported as skipped: an import that
    /// happened last week may have become the thing the user has been working in, and undo
    /// must not be a data-loss button. Directories are removed only when empty, so a
    /// directory that has acquired foreign contents also survives.
    ///
    /// A conversation that has been used since it was brought in is left whole: removing the
    /// copies that happen to be unchanged would strip its files out from under it.
    public static func revert(_ receipt: ImportReceipt) throws -> RevertResult {
        var deleted: [String] = []
        var restored: [String] = []
        var skipped: [(path: String, reason: String)] = []

        let touched = receipt.created.map(\.path) + receipt.modified.map(\.path)
            + (receipt.createdSpaces ?? []).map(\.orgRoot)
        let holders = try Guards.holders(ofStoresContaining: touched.map { URL(fileURLWithPath: $0) })
        guard holders.isEmpty else { throw UndoError.storeInUse(pids: holders.map(\.pid)) }

        let inUse = conversationsInUse(receipt)
        func belongsToUsedConversation(_ path: String) -> Bool {
            inUse.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        let fm = FileManager.default
        let deepestFirst = receipt.created.sorted {
            let a = URL(fileURLWithPath: $0.path).pathComponents.count
            let b = URL(fileURLWithPath: $1.path).pathComponents.count
            return a == b ? $0.path > $1.path : a > b
        }

        for entry in deepestFirst {
            if (try? WriteFence.check(URL(fileURLWithPath: entry.path))) == nil {
                skipped.append((entry.path, "outside the sample Mac this session is reading"))
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
                skipped.append((entry.path, alreadyAbsent))
                continue
            }
            if belongsToUsedConversation(entry.path) {
                skipped.append((entry.path, "its conversation has been used since, so all of it stays"))
                continue
            }

            if entry.isDirectory {
                guard isDirectory.boolValue else {
                    skipped.append((entry.path, "recorded as a directory but is now a file"))
                    continue
                }
                let remaining = (try? fm.contentsOfDirectory(atPath: entry.path)) ?? ["?"]
                guard remaining.isEmpty else {
                    skipped.append((entry.path, "directory is not empty (\(remaining.count) unexpected entries)"))
                    continue
                }
            } else {
                guard !isDirectory.boolValue else {
                    skipped.append((entry.path, "recorded as a file but is now a directory"))
                    continue
                }
                guard let expected = entry.sha256 else {
                    skipped.append((entry.path, "no fingerprint was recorded; refusing to delete"))
                    continue
                }
                guard let actual = try? FileDigest.hex(contentsOf: URL(fileURLWithPath: entry.path)) else {
                    skipped.append((entry.path, "could not be read to verify its fingerprint"))
                    continue
                }
                guard actual == expected else {
                    skipped.append((entry.path, "changed since the import; refusing to delete"))
                    continue
                }
            }

            do {
                try fm.removeItem(atPath: entry.path)
                deleted.append(entry.path)
            } catch {
                skipped.append((entry.path, "could not be removed: \(error.localizedDescription)"))
            }
        }

        // Files put back only while they still hold what Better Claude wrote. Anything else is
        // someone's later edit, and the copy from before stays where it is for them to use.
        let spaceFiles = Set((receipt.createdSpaces ?? []).map {
            SpaceStore.url(inOrg: URL(fileURLWithPath: $0.orgRoot)).standardizedFileURL.path
        })
        for file in receipt.modified {
            let target = URL(fileURLWithPath: file.path)
            if (try? WriteFence.check(target)) == nil {
                skipped.append((file.path, "outside the sample Mac this session is reading"))
                continue
            }
            guard fm.fileExists(atPath: file.backupPath) else {
                skipped.append((file.path, "backup is missing at \(file.backupPath)"))
                continue
            }
            if fm.fileExists(atPath: file.path) {
                guard let current = try? FileDigest.hex(contentsOf: target) else {
                    skipped.append((file.path, "could not be read to check it"))
                    continue
                }
                if current == file.sha256Before {
                    restored.append(file.path)
                    continue
                }
                guard let after = file.sha256After, after == current else {
                    // The projects this added are taken back out of it one by one below.
                    if spaceFiles.contains(target.standardizedFileURL.path) { continue }
                    skipped.append((file.path, file.sha256After == nil
                        ? "can't tell whether it changed since, so it stays. The earlier copy is at \(file.backupPath)"
                        : "changed since, so it stays. The earlier copy is at \(file.backupPath)"))
                    continue
                }
                do {
                    _ = try FileProvenance.saveCurrent(target, paths: .current)
                } catch {
                    skipped.append((file.path, "could not be copied aside first: \(error.localizedDescription)"))
                    continue
                }
            }
            do {
                try installCopy(of: URL(fileURLWithPath: file.backupPath), at: target)
                restored.append(file.path)
            } catch {
                skipped.append((file.path, "could not be restored: \(String(describing: error))"))
            }
        }

        // Projects this import added. Removed only when still empty of anything the user has
        // since attached: an extra folder means they adopted the project, and taking it away
        // would delete their work rather than ours.
        for space in receipt.createdSpaces ?? [] {
            let orgRoot = URL(fileURLWithPath: space.orgRoot)
            guard let current = SpaceStore.spaces(inOrg: orgRoot).first(where: { $0.id == space.spaceId })
            else {
                skipped.append(("project “\(space.name)”", alreadyAbsent))
                continue
            }
            guard current.name == space.name else {
                skipped.append(("project “\(space.name)”", "has been renamed since the import; leaving it"))
                continue
            }
            do {
                if try SpaceStore.remove(id: space.spaceId, fromOrg: orgRoot) {
                    deleted.append("project “\(space.name)” in \(orgRoot.lastPathComponent)")
                }
            } catch {
                skipped.append(("project “\(space.name)”", "could not be removed: \(error.localizedDescription)"))
            }
        }

        return RevertResult(deleted: deleted, restored: restored, skipped: skipped)
    }

    /// Paths belonging to a conversation this receipt brought in that has been used since:
    /// one of its transcripts or records no longer matches what was written.
    static func conversationsInUse(_ receipt: ImportReceipt) -> [String] {
        let fingerprints = Dictionary(receipt.created.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        var held: [String] = []
        for group in receipt.conversations ?? [] {
            let used = group.anchors.contains { anchor in
                guard FileManager.default.fileExists(atPath: anchor) else { return false }
                guard let expected = fingerprints[anchor] ?? nil else { return true }
                return (try? FileDigest.hex(contentsOf: URL(fileURLWithPath: anchor))) != expected
            }
            if used { held += group.anchors + group.folders }
        }
        return held
    }

    /// Copy `source` next to `destination` and rename it into place, so a restore that fails
    /// halfway leaves the original file untouched rather than truncated. The copy is staged
    /// beside the destination, so the backup can be on any volume.
    private static func installCopy(of source: URL, at destination: URL) throws {
        let destination = try AtomicWrite.resolvingLinks(destination)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let staged = parent.appendingPathComponent(AtomicWrite.temporaryName(prefix: "restore"))
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: source, to: staged)

        guard Darwin.rename(staged.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staged)
            throw AtomicWriteError.renameFailed(from: staged.path, to: destination.path, code: code)
        }
    }
}
