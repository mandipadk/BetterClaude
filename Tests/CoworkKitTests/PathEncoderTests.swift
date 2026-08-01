import Foundation
import Testing

@testable import CoworkKit

/// The encoder is verified against the real directory names on a machine with Claude
/// installed (see `cowork encode`), but those cannot be committed. These vectors capture the
/// behaviours that matter, including the ones that look like bugs and are not.
@Suite("PathEncoder")
struct PathEncoderTests {

    @Test("Leading slash becomes a leading dash")
    func vmPath() {
        #expect(PathEncoder.encode("/sessions/confident-affectionate-bohr")
                == "-sessions-confident-affectionate-bohr")
    }

    @Test("Every non-alphanumeric maps to one dash, and runs are not collapsed")
    func runsPreserved() {
        // A directory named `.claude-worktrees` produces a double dash from `/` + `.`.
        #expect(PathEncoder.encode("/a/.claude-worktrees/foo") == "-a--claude-worktrees-foo")
        #expect(PathEncoder.encode("/x/a.b") == "-x-a-b")
        #expect(PathEncoder.encode("/x/a_b") == "-x-a-b")
        #expect(PathEncoder.encode("/x/a b") == "-x-a-b")
    }

    @Test("Trailing separators are significant")
    func trailingSlash() {
        #expect(PathEncoder.encode("/sessions/x/") != PathEncoder.encode("/sessions/x"))
        #expect(PathEncoder.encode("/sessions/x/") == "-sessions-x-")
    }

    @Test("Non-ASCII expands per UTF-16 code unit, not per character")
    func utf16Semantics() {
        // Two BMP code points, each replaced individually, plus the leading slash.
        #expect(PathEncoder.encode("/日本") == "---")
        // An astral character occupies two UTF-16 code units and so yields two dashes.
        #expect(PathEncoder.encode("/😀") == "---")
    }

    @Test("A 200-character result is not hashed; 201 is")
    func truncationBoundary() {
        let exactly200 = "/" + String(repeating: "a", count: 199)
        #expect(PathEncoder.sanitize(exactly200).count == 200)
        #expect(!PathEncoder.encode(exactly200).contains("-a-"))
        #expect(PathEncoder.encode(exactly200).count == 200)

        let over = "/" + String(repeating: "a", count: 200)
        let encoded = PathEncoder.encode(over)
        #expect(encoded.count > 200)
        #expect(encoded.hasPrefix(String(PathEncoder.sanitize(over).prefix(200))))
    }

    @Test("The hash is taken over the original path, not the sanitized one")
    func hashesOverOriginal() {
        // These sanitize identically but must not collide, because the hash sees `.` vs `_`.
        let a = "/" + String(repeating: "a", count: 210) + ".x"
        let b = "/" + String(repeating: "a", count: 210) + "_x"
        #expect(PathEncoder.sanitize(a) == PathEncoder.sanitize(b))
        #expect(PathEncoder.encode(a) != PathEncoder.encode(b))
    }

    @Test("hash32 matches the JavaScript 31-multiplier rolling hash")
    func hashKnownAnswers() {
        // Cross-checked against `node -e "…"` using the recovered reference implementation.
        #expect(PathEncoder.hash32("") == 0)
        #expect(PathEncoder.hash32("a") == 97)
        #expect(PathEncoder.hash32("ab") == 3105)
        #expect(PathEncoder.hash32("hello") == 99162322)
    }

    @Test("Symlinked paths resolve the way realpath(3) does, not the way Foundation does")
    func realpathSemantics() {
        // Foundation's `resolvingSymlinksInPath()` special-cases `/private/tmp` back to
        // `/tmp`, which is the opposite of `realpath(3)` — and the CLI resolves with
        // `fs.realpath`. Encoding `/tmp/…` while the CLI encodes `/private/tmp/…` produces a
        // different directory name, and a session written under the wrong name is invisible
        // in the resume picker with no error to explain it.
        let resolved = PathEncoder.resolvedPath("/tmp")
        #expect(resolved == "/private/tmp")
        #expect(PathEncoder.encode(resolving: "/tmp") == "-private-tmp")
        #expect(URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path == "/tmp",
                "if Foundation stops shortening this, the workaround can be revisited")
    }

    @Test("A path that does not exist yet still resolves through its real ancestor")
    func resolvesNonexistentPaths() {
        let resolved = PathEncoder.resolvedPath("/tmp/definitely-not-here-\(UUID().uuidString)/deep")
        #expect(resolved.hasPrefix("/private/tmp/"))
        #expect(resolved.hasSuffix("/deep"))
    }

    @Test("Int32.min magnitude does not trap and matches Math.abs")
    func hashMinInt() {
        // Math.abs(-2147483648) is 2147483648 in JavaScript — a value Int32 cannot hold, so
        // the magnitude must be widened rather than negated.
        #expect(UInt64(Int32.min.magnitude) == 2_147_483_648)
        #expect(String(UInt64(Int32.min.magnitude), radix: 36) == "zik0zk")
    }
}
