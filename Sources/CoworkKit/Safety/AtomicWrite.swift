import Foundation

public enum AtomicWriteError: Error, CustomStringConvertible {
    case crossDevice(String, String)
    case openFailed(path: String, code: Int32)
    case writeFailed(path: String, code: Int32)
    case syncFailed(path: String, code: Int32)
    case renameFailed(from: String, to: String, code: Int32)
    case missing(String)
    case notADirectory(String)
    case unresolvablePath(String)

    public var description: String {
        switch self {
        case .crossDevice(let a, let b):
            return "\(a) and \(b) are on different volumes; rename(2) cannot be atomic across devices"
        case .openFailed(let p, let c):
            return "could not create temporary file at \(p): \(Self.strerror(c))"
        case .writeFailed(let p, let c):
            return "could not write \(p): \(Self.strerror(c))"
        case .syncFailed(let p, let c):
            return "could not flush \(p): \(Self.strerror(c))"
        case .renameFailed(let from, let to, let c):
            return "could not rename \(from) to \(to): \(Self.strerror(c))"
        case .missing(let p):
            return "no such file or directory: \(p)"
        case .notADirectory(let p):
            return "not a directory: \(p)"
        case .unresolvablePath(let p):
            return "no existing ancestor for \(p); cannot determine its volume"
        }
    }

    static func strerror(_ code: Int32) -> String {
        String(cString: Darwin.strerror(code)) + " (errno \(code))"
    }
}

/// Publishes files and directories into a live store with a single `rename(2)`.
///
/// Claude Desktop lists sessions by scanning the store directory while we are writing to it,
/// so a partially written file must never be visible under a name the app will pick up.
/// Two properties do the work: the staging name is dot-prefixed, which puts it outside the
/// app's `local_*` prefix filter even during the window it exists, and the move into place
/// is `rename(2)`, which is atomic with respect to any concurrent reader on the same volume.
///
/// `FileManager.moveItem` is deliberately not used — it is documented as a move, not as an
/// atomic replace, and it falls back to copy-then-delete in cases we cannot enumerate.
public enum AtomicWrite {

    /// Write `data` so that `url` either has its old contents or the complete new contents,
    /// never a prefix of the new contents.
    ///
    /// A symlink at `url` is followed and its target replaced, so the link survives. A file
    /// that is already there keeps its permissions and extended attributes. A new one gets
    /// `newFileMode`, or 0600 inside a Claude Code folder, which is what Claude Code uses.
    public static func write(_ data: Data, to url: URL, newFileMode: mode_t? = nil) throws {
        try WriteFence.check(url)
        let target = try resolvingLinks(url)
        if target != url.standardizedFileURL { try WriteFence.check(target) }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var existing = stat()
        let replacing = stat(target.path, &existing) == 0 && (existing.st_mode & S_IFMT) == S_IFREG
        let mode = newFileMode ?? (isClaudeCodeLocation(target) ? 0o600 : 0o644)

        let temporary = directory.appendingPathComponent(temporaryName(prefix: "write"))
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw AtomicWriteError.openFailed(path: temporary.path, code: errno)
        }

        do {
            if replacing {
                let source = Darwin.open(target.path, O_RDONLY)
                if source >= 0 {
                    // Best effort: an attribute the system won't let us set is not worth failing over.
                    _ = fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
                    Darwin.close(source)
                }
                _ = fchmod(fd, existing.st_mode & 0o7777)
            }
            try writeAll(data, to: fd, path: temporary.path)
            guard Darwin.fsync(fd) == 0 else {
                throw AtomicWriteError.syncFailed(path: temporary.path, code: errno)
            }
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        Darwin.close(fd)

        guard Darwin.rename(temporary.path, target.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw AtomicWriteError.renameFailed(from: temporary.path, to: target.path, code: code)
        }
        syncDirectory(directory)
    }

    /// The file a path finally names, following a symlink at the last component (and any it
    /// points to). The folders above are left as written: `rename(2)` follows those itself.
    static func resolvingLinks(_ url: URL) throws -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            else { return current }
            current = (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
        }
        throw AtomicWriteError.openFailed(path: url.path, code: ELOOP)
    }

    /// Inside `~/.claude`, a `.claude-*` copy, `~/.claude.json`, or the configured config folder.
    static func isClaudeCodeLocation(_ url: URL) -> Bool {
        let config = HostPaths.current.claudeCodeConfigDir.standardizedFileURL.path
        return url.pathComponents.contains { $0.hasPrefix(".claude") } || url.path.hasPrefix(config + "/")
    }

    /// Install a fully built directory at `finalURL`, replacing whatever is there.
    ///
    /// On APFS and HFS+ this is a single `renamex_np(RENAME_SWAP)`, so no reader ever
    /// observes `finalURL` missing. Filesystems without swap support fall back to
    /// displace-then-rename, which has a brief window where `finalURL` does not exist; the
    /// displaced original is renamed back if the second rename fails.
    public static func replaceDirectory(stagedAt staged: URL, with finalURL: URL) throws {
        try WriteFence.check(finalURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: staged.path, isDirectory: &isDirectory) else {
            throw AtomicWriteError.missing(staged.path)
        }
        guard isDirectory.boolValue else {
            throw AtomicWriteError.notADirectory(staged.path)
        }

        let parent = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try ensureSameVolume(staged, parent)

        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            guard Darwin.rename(staged.path, finalURL.path) == 0 else {
                throw AtomicWriteError.renameFailed(from: staged.path, to: finalURL.path, code: errno)
            }
            syncDirectory(parent)
            return
        }

        if renamex_np(staged.path, finalURL.path, UInt32(RENAME_SWAP)) == 0 {
            // `staged` now holds the previous contents of `finalURL`.
            try? FileManager.default.removeItem(at: staged)
            syncDirectory(parent)
            return
        }
        let swapErrno = errno
        guard swapErrno == ENOTSUP || swapErrno == EINVAL else {
            throw AtomicWriteError.renameFailed(from: staged.path, to: finalURL.path, code: swapErrno)
        }

        let displaced = parent.appendingPathComponent(temporaryName(prefix: "replaced"))
        guard Darwin.rename(finalURL.path, displaced.path) == 0 else {
            throw AtomicWriteError.renameFailed(from: finalURL.path, to: displaced.path, code: errno)
        }
        if Darwin.rename(staged.path, finalURL.path) != 0 {
            let code = errno
            _ = Darwin.rename(displaced.path, finalURL.path)
            throw AtomicWriteError.renameFailed(from: staged.path, to: finalURL.path, code: code)
        }
        try? FileManager.default.removeItem(at: displaced)
        syncDirectory(parent)
    }

    /// Fail before staging anything if the staged path and its destination straddle a mount
    /// point, since `rename(2)` returns `EXDEV` there rather than degrading to a copy.
    ///
    /// Either path may not exist yet; the nearest existing ancestor determines the volume.
    public static func ensureSameVolume(_ a: URL, _ b: URL) throws {
        let deviceA = try deviceID(of: a)
        let deviceB = try deviceID(of: b)
        guard deviceA == deviceB else {
            throw AtomicWriteError.crossDevice(a.path, b.path)
        }
    }

    /// A staging name Claude Desktop's `local_*` filter will not match even if it is briefly
    /// visible, and that the Finder and directory scanners treat as hidden.
    public static func temporaryName(prefix: String) -> String {
        ".betterclaude-\(prefix)-\(UUID().uuidString).partial"
    }

    // MARK: - Internals

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AtomicWriteError.writeFailed(path: path, code: errno)
                }
                if n == 0 { throw AtomicWriteError.writeFailed(path: path, code: EIO) }
                offset += n
            }
        }
    }

    /// Make the rename itself durable. Failure here is not fatal: the data is already in
    /// place for every reader, only a power loss in the next moment could lose the link.
    private static func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
    }

    /// `st_dev` of the nearest existing ancestor. `NSFileSystemNumber` is the device number,
    /// which is what `rename(2)` compares before returning `EXDEV`.
    private static func deviceID(of url: URL) throws -> Int {
        var probe = url.standardizedFileURL
        while true {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: probe.path),
               let device = attributes[.systemNumber] as? NSNumber {
                return device.intValue
            }
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent.path == probe.path { throw AtomicWriteError.unresolvablePath(url.path) }
            probe = parent
        }
    }
}
