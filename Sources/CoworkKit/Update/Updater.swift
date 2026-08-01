import CryptoKit
import Foundation

/// What a published release says about itself.
///
/// `Codable` is right here for the same reason it is right for `Manifest` and wrong for
/// session data: this is our own format, versioned by us, with no unknown keys to preserve.
public struct Appcast: Codable, Sendable {
    public let version: String
    public let build: String?
    public let minimumSystemVersion: String?
    public let publishedAt: Date?
    public let zipURL: URL
    public let zipSHA256: String
    public let dmgURL: URL?
    public let notes: String?
}

public struct AvailableUpdate: Sendable {
    public let appcast: Appcast
    public let currentVersion: String

    public var version: String { appcast.version }
    public var notes: String? { appcast.notes }
}

public enum UpdateError: Error, CustomStringConvertible {
    case notReachable(String)
    case malformedAppcast(String)
    case checksumMismatch
    case unpackFailed(String)
    case notAnApplication
    case insecureURL(URL)
    case systemTooOld(required: String)

    public var description: String {
        switch self {
        case .notReachable(let why): return "Could not reach the update server: \(why)"
        case .malformedAppcast(let why): return "The update information was unreadable: \(why)"
        case .checksumMismatch:
            return "The download did not match its published checksum and was discarded."
        case .unpackFailed(let why): return "The download could not be unpacked: \(why)"
        case .notAnApplication: return "The download did not contain an application."
        case .insecureURL(let url): return "Refusing to download over an insecure URL: \(url)"
        case .systemTooOld(let required): return "That update needs macOS \(required) or later."
        }
    }
}

/// Checks whether a newer release exists, and installs it on request.
///
/// ## What this does and does not protect against
///
/// The download is fetched over HTTPS and its SHA-256 is checked against the value in the
/// appcast before anything is unpacked. That defends against a corrupted or truncated
/// download, and against a CDN or network position that can alter bytes in flight.
///
/// It does **not** defend against a compromised release pipeline: the checksum and the
/// archive are published by the same account, so anyone who can publish a release can
/// publish a matching checksum. Real protection needs a signature the app verifies against a
/// public key compiled into it — Sparkle's EdDSA scheme — or a Developer ID identity plus
/// notarisation so Gatekeeper does the verifying. This app is ad-hoc signed and has neither.
///
/// The consequence is stated to the user before any install, rather than being left implicit
/// in a progress bar. An updater that silently replaces a binary is a supply-chain component
/// whether or not it is described as one.
public enum Updater {

    public static let appcastURL = URL(
        string: "https://github.com/mandipadk/BetterClaude/releases/latest/download/appcast.json")!

    // MARK: - Checking

    public static func check(currentVersion: String,
                             appcast url: URL = appcastURL,
                             session: URLSession = .shared) async throws -> AvailableUpdate? {
        guard url.scheme == "https" else { throw UpdateError.insecureURL(url) }

        let data: Data
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.notReachable("HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.notReachable(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let appcast: Appcast
        do {
            appcast = try decoder.decode(Appcast.self, from: data)
        } catch {
            throw UpdateError.malformedAppcast("\(error)")
        }
        guard appcast.zipURL.scheme == "https" else { throw UpdateError.insecureURL(appcast.zipURL) }

        if let required = appcast.minimumSystemVersion,
           !systemMeets(required) {
            throw UpdateError.systemTooOld(required: required)
        }
        guard isNewer(appcast.version, than: currentVersion) else { return nil }
        return AvailableUpdate(appcast: appcast, currentVersion: currentVersion)
    }

    /// Numeric, component-wise comparison. `"1.10.0"` is newer than `"1.9.0"`, which a string
    /// comparison gets backwards.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    static func systemMeets(_ required: String) -> Bool {
        let needed = components(required)
        let running = ProcessInfo.processInfo.operatingSystemVersion
        let have = [running.majorVersion, running.minorVersion, running.patchVersion]
        for index in 0..<max(needed.count, have.count) {
            let left = index < have.count ? have[index] : 0
            let right = index < needed.count ? needed[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    // MARK: - Downloading

    /// Downloads and verifies the archive, returning the unpacked application bundle.
    ///
    /// Nothing is unpacked until the checksum matches, so a tampered or truncated archive
    /// never reaches the filesystem as executable content.
    public static func download(_ update: AvailableUpdate,
                                into directory: URL,
                                session: URLSession = .shared,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let url = update.appcast.zipURL
        guard url.scheme == "https" else { throw UpdateError.insecureURL(url) }

        let archive: Data
        do {
            let (body, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.notReachable("HTTP \(http.statusCode)")
            }
            archive = body
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.notReachable(error.localizedDescription)
        }
        progress?(0.8)

        let digest = SHA256.hash(data: archive).reduce(into: "") { $0 += String(format: "%02x", $1) }
        guard digest.caseInsensitiveCompare(update.appcast.zipSHA256) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("update.zip")
        try archive.write(to: archiveURL)

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archiveURL.path, unpacked.path]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError.unpackFailed(text.isEmpty ? "ditto exited \(ditto.terminationStatus)" : text)
        }
        progress?(1.0)

        let contents = (try? FileManager.default.contentsOfDirectory(at: unpacked,
                                                                     includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.notAnApplication
        }
        return app
    }

    // MARK: - Installing

    /// Swaps the running bundle for `newApp` and relaunches.
    ///
    /// The swap happens in a detached shell script because a process cannot reliably replace
    /// the bundle it is executing from. The script waits for this process to exit, keeps the
    /// outgoing bundle until the incoming one is in place, and restores it if the move fails
    /// — so a failed update leaves a working app rather than none.
    public static func install(newApp: URL, replacing currentApp: URL) throws -> Process {
        let script = """
        #!/bin/bash
        set -uo pipefail
        NEW=%@
        CURRENT=%@
        BACKUP="${CURRENT}.previous"

        # Wait for the running app to exit before touching its bundle.
        for _ in $(seq 1 100); do
          pgrep -f "$CURRENT/Contents/MacOS/" >/dev/null 2>&1 || break
          sleep 0.2
        done

        rm -rf "$BACKUP"
        if [ -d "$CURRENT" ]; then mv "$CURRENT" "$BACKUP" || exit 1; fi
        if ! ditto "$NEW" "$CURRENT"; then
          # Put the working copy back rather than leaving the user with nothing.
          rm -rf "$CURRENT"
          [ -d "$BACKUP" ] && mv "$BACKUP" "$CURRENT"
          exit 1
        fi
        rm -rf "$BACKUP"
        xattr -dr com.apple.quarantine "$CURRENT" 2>/dev/null
        open "$CURRENT"
        """
        let filled = String(format: script,
                            shellQuoted(newApp.path), shellQuoted(currentApp.path))

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("betterclaude-update-\(UUID().uuidString).sh")
        try Data(filled.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
        return process
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
