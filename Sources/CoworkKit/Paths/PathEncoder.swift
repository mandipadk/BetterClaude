import Foundation

/// Reimplements the directory-name encoding that Claude Code and Claude Desktop use to
/// map a working directory onto a folder under `<configDir>/projects/`.
///
/// This is the single most load-bearing function in the package: place a transcript under
/// a name this function computes wrongly and the session is silently invisible — no error,
/// it simply never appears in the resume picker.
///
/// The reference implementation, recovered from the Claude Code binary, is JavaScript:
///
/// ```js
/// function hash(e){ let t=0; for (let r=0;r<e.length;r++) t=(t<<5)-t+e.charCodeAt(r)|0; return t }
/// function encode(e){
///   let t = e.replace(/[^a-zA-Z0-9]/g, "-");
///   return t.length <= 200 ? t : `${t.slice(0,200)}-${Math.abs(hash(e)).toString(36)}`;
/// }
/// ```
///
/// Two JavaScript details are not incidental and are reproduced deliberately below:
/// `charCodeAt` and `String.replace` both operate on UTF-16 code units, so `日` becomes two
/// dashes rather than one; and `Math.abs` is applied to a JS number rather than an `Int32`,
/// so `Int32.min` yields 2147483648 instead of overflowing.
public enum PathEncoder {

    /// The length at which the encoder switches from plain sanitization to a hashed suffix.
    public static let truncationLimit = 200

    /// JavaScript `(t << 5) - t + c | 0` — a 31-multiplier rolling hash, wrapping at each
    /// step to a signed 32-bit value.
    public static func hash32(_ s: String) -> Int32 {
        var t: Int32 = 0
        for unit in s.utf16 {
            t = (t &<< 5) &- t &+ Int32(unit)
        }
        return t
    }

    /// `Math.abs(hash).toString(36)`.
    ///
    /// `Math.abs` in JavaScript operates on a double, so `abs(Int32.min)` is 2147483648 —
    /// a value that does not fit in `Int32`. Widening to `UInt64` before the magnitude is
    /// taken reproduces that exactly; `abs()` on `Int32.min` would trap in Swift.
    static func hashSuffix(_ s: String) -> String {
        let h = hash32(s)
        let magnitude = UInt64(h.magnitude)
        return String(magnitude, radix: 36, uppercase: false)
    }

    /// Replace every character outside `[A-Za-z0-9]` with a single `-`, one dash per UTF-16
    /// code unit. Runs are *not* collapsed and the result is *not* trimmed: the real store
    /// contains `…-aquaview--claude-worktrees-foo`, whose double dash comes from `/.`.
    public static func sanitize(_ path: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let isAlphanumeric =
                (unit >= 0x30 && unit <= 0x39) ||  // 0-9
                (unit >= 0x41 && unit <= 0x5A) ||  // A-Z
                (unit >= 0x61 && unit <= 0x7A)     // a-z
            if isAlphanumeric, let scalar = Unicode.Scalar(unit) {
                out.append(scalar)
            } else {
                out.append("-")
            }
        }
        return String(out)
    }

    /// Encode an already-resolved absolute path. Callers that hold a path straight from the
    /// user should use ``encode(resolving:)`` instead — the CLI applies `realpath` first,
    /// which matters on macOS where `/tmp` is a symlink to `/private/tmp`.
    public static func encode(_ realPath: String) -> String {
        // `sanitize` emits only ASCII, so character, UTF-16, and byte counts all agree and
        // `prefix` cannot split a grapheme.
        let sanitized = sanitize(realPath)
        guard sanitized.count > truncationLimit else { return sanitized }
        // The hash is computed over the *original* path, not the sanitized one.
        return "\(sanitized.prefix(truncationLimit))-\(hashSuffix(realPath))"
    }

    /// Resolve symlinks, then encode. This matches the CLI, which calls `fs.realpath`
    /// before encoding.
    public static func encode(resolving path: String) -> String {
        encode(resolvedPath(path))
    }

    /// `realpath(3)` where the path exists; otherwise resolve the deepest existing ancestor
    /// and re-append the remainder, so a not-yet-created project directory still encodes to
    /// the name the CLI will use once it exists.
    ///
    /// This deliberately calls `realpath(3)` rather than `URL.resolvingSymlinksInPath()`.
    /// Foundation special-cases `/private/tmp` *back* to `/tmp`, which is the opposite of
    /// what `realpath` — and therefore the Claude Code CLI, which resolves with
    /// `fs.realpath` — produces. Encoding `/tmp/…` when the CLI encodes `/private/tmp/…`
    /// yields a different directory name, and a session written under the wrong name is
    /// invisible to the resume picker with no error to explain it.
    public static func resolvedPath(_ path: String) -> String {
        if let resolved = posixRealpath(path) { return resolved }

        var components: [String] = []
        var probe = URL(fileURLWithPath: path).standardizedFileURL
        while probe.path != "/" {
            let parent = probe.deletingLastPathComponent()
            components.append(probe.lastPathComponent)
            probe = parent
            if let base = posixRealpath(probe.path) {
                let tail = components.reversed().joined(separator: "/")
                return base == "/" ? "/\(tail)" : "\(base)/\(tail)"
            }
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func posixRealpath(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// All project directories that could hold transcripts for `realPath`, most likely first.
    ///
    /// The 32-bit hash is weak, so two long paths can legitimately encode to the same
    /// truncated prefix with different suffixes — and the CLI itself enumerates every
    /// sibling sharing the 200-character prefix rather than assuming uniqueness. Any
    /// reimplementation that assumes a single candidate will miss transcripts.
    public static func candidateDirectories(for realPath: String, in projectsDir: URL) throws -> [URL] {
        let exact = encode(realPath)
        let exactURL = projectsDir.appendingPathComponent(exact, isDirectory: true)

        let sanitized = sanitize(realPath)
        guard sanitized.utf16.count > truncationLimit else {
            return FileManager.default.fileExists(atPath: exactURL.path) ? [exactURL] : []
        }

        let prefix = exact.prefix(truncationLimit) + "-"
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil)) ?? []

        var result: [URL] = []
        if FileManager.default.fileExists(atPath: exactURL.path) { result.append(exactURL) }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.lastPathComponent.hasPrefix(prefix) && entry.path != exactURL.path {
            result.append(entry)
        }
        return result
    }
}
