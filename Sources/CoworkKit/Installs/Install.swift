import Foundation

/// One Claude on this Mac: Claude Desktop, another copy of it (a Parallex copy or an older
/// launcher variant), Claude Science, or Claude Code.
///
/// This is the unit a person thinks in — "my work Claude", "Claude Code" — rather than the
/// storage units underneath (a store, an account, an org). Everything the app shows about an
/// install hangs off `dataRoot`.
public struct Install: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Claude Desktop, or a copy of it launched with its own data folder by a launcher.
        case desktop
        /// A copy of Claude Desktop made by Parallex.
        case parallex(slug: String)
        case science
        case claudeCode
    }

    public struct Badge: Sendable, Hashable {
        public let text: String
        public let colorHex: String?
    }

    public let id: String
    public let kind: Kind
    public let name: String
    public let dataRoot: URL
    /// The app that opens this install. `nil` for Claude Code, and for a copy whose app is
    /// gone.
    public let appURL: URL?
    /// Where to draw the icon from: an app bundle or an image file.
    public let iconURL: URL?
    public let badge: Badge?
    /// The Cowork session store, when this install has one.
    public let store: StoreRef?

    /// Where the Desktop app's Code tab keeps its session list, if it has one.
    public var codeTabRoot: URL? {
        guard kind == .desktop || isParallex else { return nil }
        let url = dataRoot.appendingPathComponent("claude-code-sessions", isDirectory: true)
        return Discovery.isDirectory(url) ? url : nil
    }

    public var isParallex: Bool {
        if case .parallex = kind { return true }
        return false
    }

    /// Whether this is a Claude Desktop, in any of its copies.
    public var isDesktop: Bool { kind == .desktop || isParallex }

    public init(id: String, kind: Kind, name: String, dataRoot: URL, appURL: URL?,
                iconURL: URL?, badge: Badge?, store: StoreRef?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.dataRoot = dataRoot
        self.appURL = appURL
        self.iconURL = iconURL
        self.badge = badge
        self.store = store
    }
}

/// Finds every Claude on this Mac.
///
/// Four sources, each read only:
/// - Application Support folders that hold Claude Desktop data — the default `Claude`, and
///   any folder a launcher variant pointed Claude at;
/// - Parallex's records of the copies it made (see ``ParallexInstances``);
/// - `~/.claude-science` beside the Claude Science app;
/// - Claude Code's config folder.
public enum InstallDiscovery {

    public static let scienceBundleIdentifier = "com.anthropic.operon"

    /// Files and folders only Claude Desktop creates. A folder with none of them is some
    /// other Electron app's data, whatever it is called.
    static let desktopMarkers = ["claude_desktop_config.json", StoreLayout.sessionsDirName,
                                 "claude-code-sessions", "cowork_settings.json",
                                 "Claude Extensions"]

    /// Folders in Application Support that belong to other apps in this family and are never
    /// a Claude install themselves.
    static let notInstalls: Set<String> = ["Parallex", "BetterClaude"]

    public static func all() -> [Install] {
        desktopInstalls() + parallexInstalls() + [science(), claudeCode()].compactMap { $0 }
    }

    // MARK: Desktop

    static func desktopInstalls() -> [Install] {
        let root = HostPaths.current.applicationSupport
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let launchers = Discovery.launcherIndex()
        // A variant with no launcher of its own is still Claude's data, so it wears Claude's
        // icon rather than a blank one.
        let claudeApp = application(withIdentifier: Discovery.electronBundleIdentifier)
        let defaultRoot = Discovery.canonical(root.appendingPathComponent("Claude", isDirectory: true))

        var result: [Install] = []
        for entry in entries where Discovery.isDirectory(entry) {
            guard !notInstalls.contains(entry.lastPathComponent) else { continue }
            let isClaude = desktopMarkers.contains {
                FileManager.default.fileExists(atPath: entry.appendingPathComponent($0).path)
            }
            guard isClaude else { continue }

            let dataRoot = Discovery.canonical(entry)
            let launcher = launchers[dataRoot.path]
            let name = dataRoot == defaultRoot
                ? "Claude"
                : (launcher?.displayName ?? entry.lastPathComponent)
            result.append(Install(
                id: "desktop:\(dataRoot.path)", kind: .desktop, name: name, dataRoot: dataRoot,
                appURL: launcher?.bundleURL, iconURL: launcher?.bundleURL ?? claudeApp, badge: nil,
                store: store(at: dataRoot, name: entry.lastPathComponent, launcher: launcher)))
        }
        // The default install first, then the rest by name.
        return result.sorted {
            if ($0.dataRoot == defaultRoot) != ($1.dataRoot == defaultRoot) { return $0.dataRoot == defaultRoot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Parallex

    static func parallexInstalls() -> [Install] {
        ParallexInstances.claudeCopies().map { copy in
            let launcher = copy.appURL.map {
                LauncherRef(bundleURL: $0, bundleIdentifier: copy.bundleIdentifier ?? "",
                            displayName: copy.name, kind: .parallexCopy,
                            userDataDirOverride: copy.dataRoot)
            }
            return Install(
                id: "parallex:\(copy.slug)", kind: .parallex(slug: copy.slug), name: copy.name,
                dataRoot: copy.dataRoot, appURL: copy.appURL,
                iconURL: copy.customIconURL ?? copy.appURL,
                badge: copy.badgeText.map { Install.Badge(text: $0, colorHex: copy.badgeColorHex) },
                store: store(at: copy.dataRoot, name: copy.name, launcher: launcher))
        }
    }

    /// Claude Desktop copies made by Parallex, as session stores.
    static func parallexStores() -> [StoreRef] {
        parallexInstalls().compactMap(\.store)
    }

    // MARK: Science and Claude Code

    static func science() -> Install? {
        let dataRoot = HostPaths.current.home.appendingPathComponent(".claude-science", isDirectory: true)
        let app = application(withIdentifier: scienceBundleIdentifier)
        guard Discovery.isDirectory(dataRoot) || app != nil else { return nil }
        return Install(id: "science:\(dataRoot.path)", kind: .science, name: "Claude Science",
                       dataRoot: dataRoot, appURL: app, iconURL: app, badge: nil, store: nil)
    }

    static func claudeCode() -> Install? {
        let config = HostPaths.current.claudeCodeConfigDir
        guard Discovery.isDirectory(config) else { return nil }
        return Install(id: "claude-code:\(config.path)", kind: .claudeCode, name: "Claude Code",
                       dataRoot: config, appURL: nil, iconURL: nil, badge: nil, store: nil)
    }

    // MARK: Helpers

    static func store(at dataRoot: URL, name: String, launcher: LauncherRef?) -> StoreRef? {
        let sessions = dataRoot.appendingPathComponent(StoreLayout.sessionsDirName, isDirectory: true)
        guard Discovery.isDirectory(sessions) else { return nil }
        return StoreRef(variantDirName: name, userDataDir: dataRoot, sessionsRoot: sessions,
                        launcher: launcher)
    }

    static func application(withIdentifier identifier: String) -> URL? {
        for directory in HostPaths.current.applicationDirectories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            for bundle in entries where bundle.pathExtension == "app"
                && ParallexInstances.bundleIdentifier(of: bundle) == identifier {
                return bundle
            }
        }
        return nil
    }
}
