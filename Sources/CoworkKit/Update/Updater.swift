import CryptoKit
import Foundation

/// The checksum manifest published beside each release for Better Claude 0.1.x, whose updater
/// reads `releases/latest/download/appcast.json`. Newer versions verify a signature instead.
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

/// A published release the updater can install.
public struct AvailableUpdate: Sendable {
    public let version: String
    public let notes: String?
    public let pageURL: URL
    /// The app, zipped: `BetterClaude-<version>.zip`.
    public let archiveURL: URL
    /// Its Ed25519 signature, base64: `BetterClaude-<version>.zip.sig`.
    public let signatureURL: URL
    public let currentVersion: String
}

public enum UpdateError: Error, CustomStringConvertible {
    case notReachable(String)
    case malformedAppcast(String)
    case notSigned
    case badSignature
    case unpackFailed(String)
    case notAnApplication
    case wrongApplication
    case insecureURL(URL)
    case systemTooOld(required: String)

    public var description: String {
        switch self {
        case .notReachable(let why): return "Couldn't reach the update server: \(why)"
        case .malformedAppcast(let why): return "The update information was unreadable: \(why)"
        case .notSigned: return "The latest release has no signed app, so it can't be installed from here."
        case .badSignature: return "The download isn't signed by Better Claude, so it wasn't installed."
        case .unpackFailed(let why): return "The download couldn't be unpacked: \(why)"
        case .notAnApplication: return "The download didn't contain the app."
        case .wrongApplication: return "The download didn't match the release it came from, so it wasn't installed."
        case .insecureURL(let url): return "Refusing to download over an insecure address: \(url)"
        case .systemTooOld(let required): return "That update needs macOS \(required) or later."
        }
    }
}

/// Verifies release archives against the public key compiled into the app. The private key
/// never leaves the release machine's keychain (see `Scripts/release-key.swift`).
public enum ReleaseSignature {
    public static let publicKey = "W3KaTeYI+tHD+bbAO7H45qmPR0vGO9qPcn3gzfQmMGc="

    public static func verify(_ data: Data, signature: String, publicKey: String = publicKey) -> Bool {
        guard let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signatureData, for: data)
    }
}

/// Checks for a newer release, and installs it on request.
///
/// An update is installed only when its archive carries a valid signature from the Better
/// Claude release key — checked against the public key compiled into this app — and unpacks
/// to Better Claude at the version the release claims. HTTPS alone would only prove the
/// bytes came from GitHub; the signature proves they came from whoever holds the key, so a
/// compromised release account can't push an update on its own.
public enum Updater {

    public static let repository = "mandipadk/BetterClaude"
    public static let feedURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    public static func archiveName(for version: String) -> String { "BetterClaude-\(version).zip" }

    // MARK: - Checking

    public static func check(currentVersion: String, feed url: URL = feedURL,
                             session: URLSession = .shared) async throws -> AvailableUpdate? {
        guard url.scheme == "https" else { throw UpdateError.insecureURL(url) }
        let data: Data
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("BetterClaude/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.notReachable(http.statusCode == 404 ? "no release is published yet" : "HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.notReachable(error.localizedDescription)
        }
        let release = try parseRelease(data, currentVersion: currentVersion)
        return isNewer(release.version, than: currentVersion) ? release : nil
    }

    /// Reads GitHub's latest-release answer. A release without a signed archive is refused
    /// rather than offered: there would be nothing safe to install.
    public static func parseRelease(_ data: Data, currentVersion: String) throws -> AvailableUpdate {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateError.malformedAppcast("\(error)")
        }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let name = archiveName(for: version)
        guard release.draft != true, release.prerelease != true,
              let archive = release.assets.first(where: { $0.name == name }),
              let signature = release.assets.first(where: { $0.name == name + ".sig" })
        else { throw UpdateError.notSigned }
        guard archive.browser_download_url.scheme == "https", signature.browser_download_url.scheme == "https"
        else { throw UpdateError.insecureURL(archive.browser_download_url) }
        return AvailableUpdate(version: version, notes: release.body, pageURL: release.html_url,
                               archiveURL: archive.browser_download_url,
                               signatureURL: signature.browser_download_url, currentVersion: currentVersion)
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

    /// Downloads the archive and its signature, verifies, unpacks, and checks the app inside.
    /// Returns the unpacked application. Nothing is unpacked until the signature holds.
    public static func download(_ update: AvailableUpdate, into directory: URL,
                                expectingBundleIdentifier bundleIdentifier: String?,
                                session: URLSession = .shared,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        func fetch(_ url: URL) async throws -> Data {
            guard url.scheme == "https" else { throw UpdateError.insecureURL(url) }
            do {
                let (body, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw UpdateError.notReachable("HTTP \(http.statusCode)")
                }
                return body
            } catch let error as UpdateError {
                throw error
            } catch {
                throw UpdateError.notReachable(error.localizedDescription)
            }
        }
        let signature = String(decoding: try await fetch(update.signatureURL), as: UTF8.self)
        progress?(0.1)
        let archive = try await fetch(update.archiveURL)
        progress?(0.8)
        guard ReleaseSignature.verify(archive, signature: signature) else { throw UpdateError.badSignature }

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

        let contents = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.notAnApplication }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == update.version,
              bundleIdentifier == nil || info?["CFBundleIdentifier"] as? String == bundleIdentifier
        else { throw UpdateError.wrongApplication }
        return app
    }

    // MARK: - Installing

    /// Swaps the running bundle for `newApp` and relaunches.
    ///
    /// The swap happens in a detached shell script because a process cannot reliably replace
    /// the bundle it is executing from. The script waits for this process to exit, keeps the
    /// outgoing bundle until the incoming one is in place, and restores it if the move fails
    /// — so a failed update leaves a working app rather than none.
    public static func install(newApp: URL, replacing currentApp: URL,
                               waitFor pid: Int32 = ProcessInfo.processInfo.processIdentifier)
        throws -> Process {
        let script = """
        #!/bin/bash
        set -uo pipefail
        NEW=%@
        CURRENT=%@
        WAIT_PID=%@
        BACKUP="${CURRENT}.previous"

        # Wait for the running app to exit before touching its bundle.
        #
        # This waits on our own process id rather than pattern-matching the bundle path.
        # `pgrep -f "$CURRENT/..."` reads its argument as an extended regular expression, so a
        # bundle at "BetterClaude (1).app" — precisely what a browser produces on a second
        # download — never matches, the loop falls through immediately, and the script replaces
        # the bundle out from under the running app. A pid is exact and has no syntax.
        for _ in $(seq 1 100); do
          kill -0 "$WAIT_PID" 2>/dev/null || break
          sleep 0.2
        done
        # Still running: replacing a bundle under a live app breaks it. Leave both as they
        # are; the update is offered again next time.
        kill -0 "$WAIT_PID" 2>/dev/null && exit 1

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
                            shellQuoted(newApp.path), shellQuoted(currentApp.path),
                            String(pid))

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
