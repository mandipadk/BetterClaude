import Foundation
import Testing

@testable import CoworkKit

@Suite("Updater")
struct UpdaterTests {

    @Test("Versions compare numerically, not as strings")
    func versionOrdering() {
        // The case a string comparison gets backwards.
        #expect(Updater.isNewer("1.10.0", than: "1.9.0"))
        #expect(!Updater.isNewer("1.9.0", than: "1.10.0"))

        #expect(Updater.isNewer("2.0.0", than: "1.99.99"))
        #expect(Updater.isNewer("1.0.1", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("0.9.0", than: "1.0.0"))
    }

    @Test("Missing components are treated as zero")
    func shortVersions() {
        #expect(Updater.isNewer("1.1", than: "1"))
        #expect(!Updater.isNewer("1", than: "1.0.0"))
        #expect(Updater.isNewer("1.0.1", than: "1.0"))
    }

    @Test("Pre-release and build suffixes do not break ordering")
    func suffixedVersions() {
        #expect(Updater.isNewer("1.2.0", than: "1.1.0-beta"))
        #expect(!Updater.isNewer("1.1.0-beta", than: "1.1.0"))
    }

    @Test("A non-HTTPS appcast is refused before any request is made")
    func refusesInsecureAppcast() async {
        let url = URL(string: "http://example.com/appcast.json")!
        await #expect(throws: UpdateError.self) {
            _ = try await Updater.check(currentVersion: "1.0.0", appcast: url)
        }
    }

    @Test("An appcast decodes from the shape the release workflow publishes")
    func decodesAppcast() throws {
        let json = """
        {"version":"1.2.3","build":"12","minimumSystemVersion":"14.0",
         "publishedAt":"2026-08-01T00:00:00Z",
         "zipURL":"https://example.com/BetterClaude-1.2.3.zip",
         "zipSHA256":"abc123","dmgURL":"https://example.com/x.dmg","notes":"Fixes things."}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let appcast = try decoder.decode(Appcast.self, from: Data(json.utf8))
        #expect(appcast.version == "1.2.3")
        #expect(appcast.zipSHA256 == "abc123")
        #expect(appcast.minimumSystemVersion == "14.0")
    }

    @Test("Optional fields may be absent")
    func decodesMinimalAppcast() throws {
        let json = """
        {"version":"2.0.0","zipURL":"https://example.com/a.zip","zipSHA256":"deadbeef"}
        """
        let appcast = try JSONDecoder().decode(Appcast.self, from: Data(json.utf8))
        #expect(appcast.version == "2.0.0")
        #expect(appcast.notes == nil)
        #expect(appcast.dmgURL == nil)
    }

    @Test("Paths with quotes cannot break out of the install script")
    func shellQuoting() {
        // A bundle path is attacker-influenced only in odd cases, but the swap script runs
        // with the user's privileges, so the quoting is worth pinning.
        #expect(Updater.shellQuoted("/Applications/My App.app") == "'/Applications/My App.app'")
        let nasty = Updater.shellQuoted("/tmp/a'; rm -rf /; echo '")
        #expect(!nasty.contains("; rm -rf /;") || nasty.hasPrefix("'"))
        #expect(nasty.hasPrefix("'") && nasty.hasSuffix("'"))
    }

    @Test("The current system satisfies a requirement it exceeds")
    func systemVersionGate() {
        #expect(Updater.systemMeets("10.0"))
        #expect(!Updater.systemMeets("99.0"))
    }

    /// The swap script must wait on a pid, never on a regex over the bundle path.
    ///
    /// `pgrep -f "$CURRENT/Contents/MacOS/"` reads its argument as an extended regular
    /// expression. A bundle at `BetterClaude (1).app` — what a browser produces on a second
    /// download — therefore never matches, so the wait loop falls straight through and the
    /// script replaces the bundle while the app is still running. Verified against a real
    /// `pgrep` before this was changed: it reported no match for a live process.
    @Test("The swap waits on a pid, not on a pattern over the bundle path")
    func swapWaitsOnPid() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("updater-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // A path holding characters that are regex metacharacters but ordinary in a filename.
        let awkward = staging.appendingPathComponent("My (Apps) [v2]/BetterClaude (1).app")
        let process = try Updater.install(newApp: staging.appendingPathComponent("new.app"),
                                          replacing: awkward,
                                          waitFor: 999_999)
        process.terminate()

        let scripts = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
        let script = scripts.filter { $0.lastPathComponent.hasPrefix("betterclaude-update-") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .first { $0.contains("BetterClaude (1).app") }
        let body = try #require(script, "the generated swap script should be on disk")

        #expect(body.contains("WAIT_PID=999999"))
        #expect(body.contains("kill -0"))
        // The regression itself: no pattern-matching over the path. Comments are excluded
        // because the script explains the bug it is avoiding, and says its name to do so.
        let executable = body.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        #expect(!executable.contains { $0.contains("pgrep") })
    }
}
