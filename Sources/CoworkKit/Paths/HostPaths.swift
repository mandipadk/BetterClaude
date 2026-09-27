import Foundation

/// Where this machine keeps everything the engine reads: the home folder, Application
/// Support, the folders apps are installed in, and Claude Code's config directory.
///
/// Every path the engine derives starts here, so a whole synthetic Mac can stand in for the
/// real one. Tests bind one per test with `HostPaths.$current.withValue(_:)`, which child
/// tasks inherit; a debug build of the app reads `BC_FIXTURE_ROOT` once at launch. Release
/// builds ignore that variable entirely, so a shipped app can only ever see the real machine.
public struct HostPaths: Sendable, Equatable {
    public var home: URL
    public var applicationDirectories: [URL]
    /// `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.
    public var claudeCodeConfigDir: URL
    /// The fixture's root when this is a synthetic machine; `nil` for the real one.
    public var fixtureRoot: URL?

    public var isFixture: Bool { fixtureRoot != nil }

    public var applicationSupport: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// Better Claude's own data: receipts, caches, and kept conversations.
    public var betterClaudeSupport: URL {
        applicationSupport.appendingPathComponent("BetterClaude", isDirectory: true)
    }

    public init(home: URL, applicationDirectories: [URL], claudeCodeConfigDir: URL,
                fixtureRoot: URL? = nil) {
        self.home = home
        self.applicationDirectories = applicationDirectories
        self.claudeCodeConfigDir = claudeCodeConfigDir
        self.fixtureRoot = fixtureRoot
    }

    /// A synthetic machine laid out under `root`: `root/home` is the home folder and
    /// `root/Applications` stands in for `/Applications`.
    public static func fixture(at root: URL) -> HostPaths {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let home = root.appendingPathComponent("home", isDirectory: true)
        return HostPaths(
            home: home,
            applicationDirectories: [root.appendingPathComponent("Applications", isDirectory: true),
                                     home.appendingPathComponent("Applications", isDirectory: true)],
            claudeCodeConfigDir: home.appendingPathComponent(".claude", isDirectory: true),
            fixtureRoot: root)
    }

    /// This machine, as the process environment describes it.
    public static func fromEnvironment(_ environment: [String: String] =
                                       ProcessInfo.processInfo.environment) -> HostPaths {
        #if DEBUG
        if let root = environment["BC_FIXTURE_ROOT"], !root.isEmpty {
            return fixture(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath,
                                   isDirectory: true))
        }
        #endif
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var configDir = home.appendingPathComponent(".claude", isDirectory: true)
        if let override = environment["CLAUDE_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            configDir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                            isDirectory: true).standardizedFileURL
        }
        return HostPaths(
            home: home,
            applicationDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                     home.appendingPathComponent("Applications", isDirectory: true)],
            claudeCodeConfigDir: configDir)
    }

    /// Read once: the environment of a running process does not change underneath it.
    public static let process = fromEnvironment()

    @TaskLocal public static var current: HostPaths = process

    /// A path under the home folder, written from `~`: `<home>/Library/…` becomes `~/Library/…`.
    public func abbreviating(_ path: String) -> String {
        // On a sample Mac, its stand-in for `/Applications` reads as the real thing.
        if let root = fixtureRoot?.path, path.hasPrefix(root + "/Applications") {
            return String(path.dropFirst(root.count))
        }
        let homePath = home.path
        guard path.hasPrefix(homePath) else { return path }
        let tail = path.dropFirst(homePath.count)
        return tail.isEmpty ? "~" : "~" + tail
    }
}

public enum WriteFenceError: Error, CustomStringConvertible {
    case outsideFixture(String)

    public var description: String {
        switch self {
        case .outsideFixture(let path):
            return "refused to write \(path): this session is reading a sample Mac, and the path is outside it"
        }
    }
}

/// Keeps a session that is reading a synthetic machine from writing to the real one.
///
/// Every write path in the engine calls ``check(_:)`` before it touches the disk. On the real
/// machine the check is free; on a fixture it allows only the fixture itself and the
/// temporary directory, where transfer plans are staged.
public enum WriteFence {
    public static func check(_ url: URL, paths: HostPaths = .current) throws {
        guard let root = paths.fixtureRoot else { return }
        let target = realPath(url)
        let allowed = [realPath(root), realPath(URL(fileURLWithPath: NSTemporaryDirectory()))]
        guard allowed.contains(where: { target == $0 || target.hasPrefix($0 + "/") }) else {
            throw WriteFenceError.outsideFixture(target)
        }
    }

    /// The path with every symlink resolved, including `/var` → `/private/var`, for a file
    /// that may not exist yet: the deepest existing ancestor goes through realpath(3) and the
    /// rest is appended. Foundation's own resolution treats `/private` inconsistently between
    /// paths that exist and paths that don't, which is fatal to a prefix comparison.
    static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = Darwin.realpath(existing.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        var path = String(cString: resolved)
        for component in rest { path += (path.hasSuffix("/") ? "" : "/") + component }
        return path
    }
}
