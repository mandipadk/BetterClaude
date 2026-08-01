import CryptoKit
import Foundation

// MARK: - Scope

/// Where a configuration item lives.
///
/// The three cases are the three places Claude keeps configuration, and they are genuinely
/// different shapes rather than three paths: the global Claude Code directory owns the user's
/// own skills and agents, a project directory owns the ones checked in beside the code, and a
/// Claude Desktop variant owns plugins and extension bundles that Claude Code never sees.
public enum ConfigScope: Sendable, Hashable {
    /// `~/.claude`, or `$CLAUDE_CONFIG_DIR` when that is set.
    case claudeCodeGlobal(URL)
    /// A project root — the directory *containing* `.claude/`, not `.claude/` itself.
    case claudeCodeProject(URL)
    /// `~/Library/Application Support/<Variant>`: the variant directory name and the user
    /// data directory it names.
    case desktopVariant(String, URL)
}

extension ConfigScope {
    /// The directory this scope is rooted at.
    public var root: URL {
        switch self {
        case .claudeCodeGlobal(let url): return url
        case .claudeCodeProject(let url): return url
        case .desktopVariant(_, let url): return url
        }
    }

    public var id: String {
        switch self {
        case .claudeCodeGlobal(let url): return "global:\(url.path)"
        case .claudeCodeProject(let url): return "project:\(url.path)"
        case .desktopVariant(let name, let url): return "desktop:\(name):\(url.path)"
        }
    }

    /// Short label for a row or a picker.
    public var title: String {
        switch self {
        case .claudeCodeGlobal: return "Claude Code"
        case .claudeCodeProject(let url): return url.lastPathComponent
        case .desktopVariant(let name, _): return name
        }
    }

    /// What kind of install this is, for a column that must not jitter.
    public var familyLabel: String {
        switch self {
        case .claudeCodeGlobal: return "Global"
        case .claudeCodeProject: return "Project"
        case .desktopVariant: return "Desktop"
        }
    }

    public var path: String { root.path }
}

// MARK: - Item

public enum ConfigKind: String, Sendable, CaseIterable {
    case skill, subagent, command, mcpServer, hook, memory, plugin, setting, extensionBundle
}

extension ConfigKind {
    /// Plural heading for a group of these.
    public var title: String {
        switch self {
        case .skill: return "Skills"
        case .subagent: return "Subagents"
        case .command: return "Commands"
        case .mcpServer: return "MCP servers"
        case .hook: return "Hooks"
        case .memory: return "Memory"
        case .plugin: return "Plugins"
        case .setting: return "Settings"
        case .extensionBundle: return "Extensions"
        }
    }

    /// Display order: the things a person edits most often come first.
    public var order: Int {
        switch self {
        case .skill: return 0
        case .subagent: return 1
        case .command: return 2
        case .mcpServer: return 3
        case .hook: return 4
        case .memory: return 5
        case .plugin: return 6
        case .extensionBundle: return 7
        case .setting: return 8
        }
    }
}

public struct ConfigItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: ConfigKind
    public let name: String
    public let scope: ConfigScope
    /// The file or directory backing this item, when there is one. Items derived from a key
    /// inside a JSON file point at that file.
    public let url: URL?
    /// One-line human summary. Never contains a credential: see ``ConfigInventory/redacted(_:)``.
    public let detail: String?
    public let bytes: Int64
    public let modified: Date?
    /// Stable fingerprint of the item's content, for comparing the same name across scopes.
    public let contentHash: String?
    public let isEnabled: Bool?

    public init(id: String, kind: ConfigKind, name: String, scope: ConfigScope, url: URL?,
                detail: String?, bytes: Int64, modified: Date?, contentHash: String?,
                isEnabled: Bool?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.scope = scope
        self.url = url
        self.detail = detail
        self.bytes = bytes
        self.modified = modified
        self.contentHash = contentHash
        self.isEnabled = isEnabled
    }

    /// The identity used to line an item up against its counterpart in another scope.
    public var matchKey: String { "\(kind.rawValue)/\(name)" }
}

// MARK: - Front matter

/// A deliberately small reader for the `---` block at the top of a `SKILL.md` or an agent
/// definition.
///
/// This is not a YAML parser and must not become one. Claude reads exactly the scalar keys at
/// the top level of that block — `name`, `description`, `model`, `tools` — and a real YAML
/// dependency would buy nothing except anchors, tags and merge keys that no skill file uses.
/// Nested mappings and sequences are skipped rather than flattened, because a skill whose
/// `metadata:` block happens to contain `name:` must not have its identity silently replaced.
public enum FrontMatter {

    /// Top-level scalar keys of the front-matter block, or an empty dictionary when there is
    /// no block, when it is unterminated, or when it is not a mapping at all.
    public static func parse(_ text: String) -> [String: String] {
        // Splitting on the literal "\n" would not work: Swift treats CRLF as a single
        // `Character`, so a file with Windows line endings is one very long line and its
        // front matter is invisible. `isNewline` matches the CRLF cluster as well as CR, LF
        // and the Unicode line separators.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0) }
        guard !lines.isEmpty else { return [:] }

        // A UTF-8 BOM survives decoding and would otherwise make the opening delimiter fail
        // to match on files written by an editor that emits one.
        if lines[0].hasPrefix("\u{FEFF}") { lines[0].removeFirst() }

        guard lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        guard let end = lines.dropFirst().firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else { return [:] }

        var result: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard !line.isEmpty, line.first != " ", line.first != "\t" else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
                // Block scalar: fold the indented continuation lines into one line, which is
                // all a one-line summary can show anyway.
                var folded: [String] = []
                while index < end {
                    let continuation = lines[index]
                    guard continuation.isEmpty
                        || continuation.hasPrefix(" ") || continuation.hasPrefix("\t") else { break }
                    index += 1
                    let piece = continuation.trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { folded.append(piece) }
                }
                value = folded.joined(separator: " ")
            } else if value.isEmpty {
                // A sequence or nested mapping. Skip its body so its keys never leak upward.
                while index < end {
                    let continuation = lines[index]
                    guard continuation.hasPrefix(" ") || continuation.hasPrefix("\t")
                        || continuation.isEmpty else { break }
                    index += 1
                }
                continue
            }

            result[key] = unquoted(value)
        }
        return result
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first, last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

// MARK: - MCP inspection

/// Everything this package is willing to say about an MCP server.
///
/// The type exists so that redaction is structural rather than a discipline: there is no
/// field here that can hold a header value, an environment value, or a command argument, so
/// no future edit to the formatting code can start printing one.
public struct MCPServerSummary: Sendable, Hashable {
    public let name: String
    /// `stdio`, `http`, `sse`, or `unknown`.
    public let transport: String
    /// Host of a remote server's URL. Never the path or the query — an MCP URL routinely
    /// carries its token in the query string.
    public let host: String?
    /// Basename of a stdio server's executable. Never the arguments.
    public let commandName: String?
    public let envKeyNames: [String]
    public let headerKeyNames: [String]

    public var detail: String {
        var parts: [String] = [transport]
        if let host { parts.append(host) }
        if let commandName { parts.append(commandName) }
        if !envKeyNames.isEmpty { parts.append("env: " + envKeyNames.joined(separator: ", ")) }
        if !headerKeyNames.isEmpty {
            parts.append("headers: " + headerKeyNames.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Fingerprint material. Built from the same redacted fields the UI shows, so the hash
    /// cannot become a side channel for a value the summary refuses to print.
    public var fingerprintSource: String {
        "\(name)|\(transport)|\(host ?? "")|\(commandName ?? "")|"
            + "\(envKeyNames.joined(separator: ","))|\(headerKeyNames.joined(separator: ","))"
    }
}

// MARK: - Inventory

public enum ConfigInventory {

    // MARK: Scopes

    /// Every scope on this machine, global first, then projects, then Desktop variants.
    public static func scopes() throws -> [ConfigScope] {
        var result: [ConfigScope] = []

        let global = Discovery.defaultClaudeCodeConfigDir()
        if Discovery.isDirectory(global) { result.append(.claudeCodeGlobal(global)) }

        result.append(contentsOf: projectScopes(excluding: global))
        result.append(contentsOf: desktopScopes())
        return result
    }

    /// Project roots that have a `.claude/` directory.
    ///
    /// The list of projects comes from `~/.claude.json`, which is where Claude Code records
    /// every directory it has been run in. Scanning the disk for `.claude/` directories would
    /// mean walking the whole home folder to find the same answer.
    static func projectScopes(excluding globalDir: URL) -> [ConfigScope] {
        guard let root = try? JSONValue.parse(Data(contentsOf: homeJSONURL())),
              let projects = root["projects"]?.objectValue
        else { return [] }

        let globalPath = Discovery.canonical(globalDir).path
        var result: [ConfigScope] = []
        for key in projects.keys.sorted() {
            let dir = URL(fileURLWithPath: key, isDirectory: true)
            let dotClaude = dir.appendingPathComponent(".claude", isDirectory: true)
            guard Discovery.isDirectory(dotClaude) else { continue }
            // Running Claude Code from the home folder records the home folder as a project,
            // whose `.claude/` *is* the global configuration directory. Listing it as a
            // project would duplicate every global item under a second scope.
            guard Discovery.canonical(dotClaude).path != globalPath else { continue }
            result.append(.claudeCodeProject(dir.standardizedFileURL))
        }
        return result
    }

    /// Application Support directories that hold Claude Desktop configuration.
    ///
    /// Membership is decided by the files present, not by the directory's name: variant
    /// directories are named by whoever created the launcher, and `Claude-3p` holds nothing
    /// but a `claude_desktop_config.json`.
    static func desktopScopes() -> [ConfigScope] {
        let root = Discovery.applicationSupportDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []

        var result: [ConfigScope] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where Discovery.isDirectory(entry) {
            let markers = ["claude_desktop_config.json", "cowork_settings.json",
                           "cowork_plugins", "Claude Extensions",
                           StoreLayout.sessionsDirName]
            let matches = markers.contains {
                FileManager.default.fileExists(atPath: entry.appendingPathComponent($0).path)
            }
            guard matches else { continue }
            result.append(.desktopVariant(entry.lastPathComponent, Discovery.canonical(entry)))
        }
        return result
    }

    // MARK: Items

    public static func items(in scope: ConfigScope) throws -> [ConfigItem] {
        switch scope {
        case .claudeCodeGlobal(let dir): return globalItems(dir: dir, scope: scope)
        case .claudeCodeProject(let root): return projectItems(root: root, scope: scope)
        case .desktopVariant(_, let dir): return desktopItems(dir: dir, scope: scope)
        }
    }

    public static func everything() throws -> [ConfigItem] {
        var result: [ConfigItem] = []
        for scope in try scopes() {
            result.append(contentsOf: (try? items(in: scope)) ?? [])
        }
        return result
    }

    // MARK: Claude Code, global

    static func globalItems(dir: URL, scope: ConfigScope) -> [ConfigItem] {
        var result: [ConfigItem] = []

        result.append(contentsOf: memoryItems(
            urls: [dir.appendingPathComponent("CLAUDE.md"),
                   dir.appendingPathComponent("CLAUDE.local.md")], scope: scope))
        result.append(contentsOf: skillItems(
            root: dir.appendingPathComponent("skills", isDirectory: true),
            scope: scope, source: nil))
        result.append(contentsOf: definitionItems(
            root: dir.appendingPathComponent("agents", isDirectory: true),
            kind: .subagent, scope: scope, source: nil))
        result.append(contentsOf: definitionItems(
            root: dir.appendingPathComponent("commands", isDirectory: true),
            kind: .command, scope: scope, source: nil))

        let settingsURL = dir.appendingPathComponent("settings.json")
        let settings = json(at: settingsURL)
        result.append(contentsOf: settingItems(settings, url: settingsURL, scope: scope))
        result.append(contentsOf: hookItems(settings, url: settingsURL, scope: scope))

        result.append(contentsOf: claudeCodePluginItems(configDir: dir, settings: settings,
                                                        scope: scope))

        let homeURL = homeJSONURL()
        let home = json(at: homeURL)
        if let servers = home["mcpServers"]?.objectValue {
            result.append(contentsOf: mcpItems(servers, url: homeURL, origin: "user", scope: scope))
        }
        return result
    }

    // MARK: Claude Code, project

    static func projectItems(root: URL, scope: ConfigScope) -> [ConfigItem] {
        let dot = root.appendingPathComponent(".claude", isDirectory: true)
        var result: [ConfigItem] = []

        result.append(contentsOf: memoryItems(
            urls: [root.appendingPathComponent("CLAUDE.md"),
                   root.appendingPathComponent("CLAUDE.local.md"),
                   dot.appendingPathComponent("CLAUDE.md")], scope: scope))
        result.append(contentsOf: skillItems(
            root: dot.appendingPathComponent("skills", isDirectory: true), scope: scope, source: nil))
        result.append(contentsOf: definitionItems(
            root: dot.appendingPathComponent("agents", isDirectory: true),
            kind: .subagent, scope: scope, source: nil))
        result.append(contentsOf: definitionItems(
            root: dot.appendingPathComponent("commands", isDirectory: true),
            kind: .command, scope: scope, source: nil))

        for name in ["settings.json", "settings.local.json"] {
            let url = dot.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let settings = json(at: url)
            result.append(contentsOf: settingItems(settings, url: url, scope: scope,
                                                   prefix: name == "settings.json" ? "" : "local."))
            result.append(contentsOf: hookItems(settings, url: url, scope: scope))
        }

        // `.mcp.json` is the checked-in, shared server list; `~/.claude.json` holds the
        // per-project servers this user added privately. Both are in scope for the project.
        let projectMCP = root.appendingPathComponent(".mcp.json")
        if let servers = json(at: projectMCP)["mcpServers"]?.objectValue {
            result.append(contentsOf: mcpItems(servers, url: projectMCP, origin: "project",
                                               scope: scope))
        }
        let homeURL = homeJSONURL()
        if let entry = json(at: homeURL)["projects"]?[root.path],
           let servers = entry["mcpServers"]?.objectValue {
            result.append(contentsOf: mcpItems(servers, url: homeURL, origin: "local", scope: scope))
        }
        return result
    }

    // MARK: Claude Desktop

    static func desktopItems(dir: URL, scope: ConfigScope) -> [ConfigItem] {
        var result: [ConfigItem] = []

        let desktopConfig = dir.appendingPathComponent("claude_desktop_config.json")
        if let servers = json(at: desktopConfig)["mcpServers"]?.objectValue {
            result.append(contentsOf: mcpItems(servers, url: desktopConfig, origin: "desktop",
                                               scope: scope))
        }

        let coworkSettingsURL = dir.appendingPathComponent("cowork_settings.json")
        let coworkSettings = json(at: coworkSettingsURL)
        result.append(contentsOf: desktopPluginItems(coworkSettings, url: coworkSettingsURL,
                                                     scope: scope))

        let pluginRoot = dir.appendingPathComponent("cowork_plugins", isDirectory: true)
        for pluginDir in visibleDirectories(pluginRoot) {
            result.append(contentsOf: skillItems(
                root: pluginDir.appendingPathComponent("skills", isDirectory: true),
                scope: scope, source: pluginDir.lastPathComponent))
            result.append(contentsOf: definitionItems(
                root: pluginDir.appendingPathComponent("agents", isDirectory: true),
                kind: .subagent, scope: scope, source: pluginDir.lastPathComponent))
            result.append(contentsOf: definitionItems(
                root: pluginDir.appendingPathComponent("commands", isDirectory: true),
                kind: .command, scope: scope, source: pluginDir.lastPathComponent))
        }

        result.append(contentsOf: extensionItems(dir: dir, scope: scope))
        return result
    }

    /// `Claude Extensions/<id>/manifest.json`, with the enabled flag from the sibling
    /// `Claude Extensions Settings/<id>.json`.
    static func extensionItems(dir: URL, scope: ConfigScope) -> [ConfigItem] {
        let root = dir.appendingPathComponent("Claude Extensions", isDirectory: true)
        let settingsRoot = dir.appendingPathComponent("Claude Extensions Settings", isDirectory: true)

        var result: [ConfigItem] = []
        for bundle in visibleDirectories(root) {
            let identifier = bundle.lastPathComponent
            let manifestURL = bundle.appendingPathComponent("manifest.json")
            let manifest = json(at: manifestURL)
            let name = manifest["display_name"]?.stringValue
                ?? manifest["name"]?.stringValue ?? identifier
            let version = manifest["version"]?.stringValue
            let described = manifest["description"]?.stringValue

            let enabled = json(at: settingsRoot.appendingPathComponent("\(identifier).json"))["isEnabled"]?
                .boolValue
            var detail = [version, described].compactMap { $0 }.joined(separator: " · ")
            if detail.isEmpty { detail = identifier }

            result.append(ConfigItem(
                id: itemID(scope: scope, kind: .extensionBundle, key: identifier),
                kind: .extensionBundle, name: name, scope: scope, url: bundle,
                detail: summary(detail), bytes: footprint(of: bundle),
                modified: modificationDate(manifestURL) ?? modificationDate(bundle),
                contentHash: manifestURL.isReadableFile
                    ? hash(of: [identifier, digest(fileAt: manifestURL) ?? ""].joined(separator: "|"))
                    : nil,
                isEnabled: enabled))
        }
        return result
    }

    // MARK: Skills

    /// Skill directories under `root`, recursively, skipping hidden directories.
    ///
    /// Skills nest: `skills/<pack>/<skill>/SKILL.md` is how a bundle of related skills is
    /// installed. The walk stops descending the moment it finds a `SKILL.md`, so a skill's own
    /// bundled resources never register as further skills. Hidden directories are skipped
    /// because tools that mirror a skill tree into `.cursor/` or `.github/` produce complete
    /// duplicate copies that Claude itself never loads.
    static func skillDirectories(under root: URL, depth: Int = 0) -> [URL] {
        guard depth < 6, isDirectoryFollowingLinks(root) else { return [] }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root]
        }
        return visibleDirectories(root).flatMap { skillDirectories(under: $0, depth: depth + 1) }
    }

    static func skillItems(root: URL, scope: ConfigScope, source: String?) -> [ConfigItem] {
        skillDirectories(under: root).map { directory in
            let skillFile = directory.appendingPathComponent("SKILL.md")
            let matter = FrontMatter.parse(text(at: skillFile) ?? "")
            let name = matter["name"].flatMap { $0.isEmpty ? nil : $0 }
                ?? directory.lastPathComponent
            var detail = matter["description"] ?? ""
            if let source, !source.isEmpty {
                detail = detail.isEmpty ? source : "\(source) · \(detail)"
            }
            return ConfigItem(
                id: itemID(scope: scope, kind: .skill, key: directory.path),
                kind: .skill, name: name, scope: scope, url: directory,
                detail: summary(detail), bytes: footprint(of: directory),
                modified: modificationDate(skillFile) ?? modificationDate(directory),
                contentHash: directoryDigest(directory, primary: skillFile),
                isEnabled: nil)
        }
    }

    // MARK: Subagents and commands

    /// `*.md` definitions under `root`, recursively.
    ///
    /// Commands may be namespaced by directory — `commands/git/sync.md` is invoked as
    /// `/git:sync` — so the name is built from the path rather than the filename alone,
    /// which also keeps two same-named commands in different namespaces distinguishable.
    static func definitionItems(root: URL, kind: ConfigKind, scope: ConfigScope,
                                source: String?) -> [ConfigItem] {
        guard isDirectoryFollowingLinks(root) else { return [] }
        var result: [ConfigItem] = []
        for (url, relative) in markdownFiles(under: root) {
            let stem = relative.hasSuffix(".md") ? String(relative.dropLast(3)) : relative
            let pathName = stem.replacingOccurrences(of: "/", with: ":")

            let matter = FrontMatter.parse(text(at: url) ?? "")
            let name = matter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? pathName

            var pieces: [String] = []
            if let source, !source.isEmpty { pieces.append(source) }
            if let described = matter["description"], !described.isEmpty { pieces.append(described) }
            if let tools = matter["tools"], !tools.isEmpty { pieces.append("tools: \(tools)") }
            if let model = matter["model"], !model.isEmpty { pieces.append("model: \(model)") }

            result.append(ConfigItem(
                id: itemID(scope: scope, kind: kind, key: url.path),
                kind: kind, name: name, scope: scope, url: url,
                detail: summary(pieces.joined(separator: " · ")),
                bytes: Discovery.fileSize(url), modified: modificationDate(url),
                contentHash: digest(fileAt: url), isEnabled: nil))
        }
        return result
    }

    // MARK: Memory

    static func memoryItems(urls: [URL], scope: ConfigScope) -> [ConfigItem] {
        urls.compactMap { url in
            guard url.isReadableFile else { return nil }
            let size = Discovery.fileSize(url)
            let lines = (text(at: url) ?? "").split(separator: "\n").count
            return ConfigItem(
                id: itemID(scope: scope, kind: .memory, key: url.path),
                kind: .memory, name: url.lastPathComponent, scope: scope, url: url,
                detail: "\(lines) line\(lines == 1 ? "" : "s")",
                bytes: size, modified: modificationDate(url),
                contentHash: digest(fileAt: url), isEnabled: nil)
        }
    }

    // MARK: MCP servers

    /// Reduce one server's configuration to the fields that cannot carry a secret.
    ///
    /// Everything a server config holds beyond these is either a credential or a place one is
    /// routinely put: `env` and `headers` values obviously, but also `args` (`--api-key=…`)
    /// and a URL's query string (`?token=…`). Only key names and the URL's host survive.
    public static func inspectMCPServer(name: String, config: JSONValue) -> MCPServerSummary {
        let declared = config["type"]?.stringValue ?? config["transport"]?.stringValue
        let urlText = config["url"]?.stringValue
        let command = config["command"]?.stringValue

        let transport: String
        if let declared, !declared.isEmpty {
            transport = declared
        } else if urlText != nil {
            transport = "http"
        } else if command != nil {
            transport = "stdio"
        } else {
            transport = "unknown"
        }

        let host = urlText.flatMap { URL(string: $0)?.host }
        let commandName = command.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }

        return MCPServerSummary(
            name: name, transport: transport, host: host, commandName: commandName,
            envKeyNames: (config["env"]?.objectValue?.keys ?? []).sorted(),
            headerKeyNames: (config["headers"]?.objectValue?.keys ?? []).sorted())
    }

    static func mcpItems(_ servers: JSONObject, url: URL, origin: String,
                         scope: ConfigScope) -> [ConfigItem] {
        servers.orderedPairs.map { pair in
            let summary = inspectMCPServer(name: pair.key, config: pair.value)
            return ConfigItem(
                id: itemID(scope: scope, kind: .mcpServer, key: "\(origin)/\(pair.key)"),
                kind: .mcpServer, name: pair.key, scope: scope, url: url,
                detail: "\(summary.detail) · \(origin)", bytes: 0,
                modified: modificationDate(url),
                contentHash: hash(of: summary.fingerprintSource), isEnabled: nil)
        }
    }

    // MARK: Hooks

    /// `hooks: { <Event>: [ { matcher, hooks: [ { type, command } ] } ] }`.
    static func hookItems(_ settings: JSONValue, url: URL, scope: ConfigScope) -> [ConfigItem] {
        guard let hooks = settings["hooks"]?.objectValue else { return [] }
        var result: [ConfigItem] = []
        for (event, value) in hooks.orderedPairs {
            guard let groups = value.arrayValue else { continue }
            for (groupIndex, group) in groups.enumerated() {
                let matcher = group["matcher"]?.stringValue ?? ""
                let commands = (group["hooks"]?.arrayValue ?? []).compactMap {
                    $0["command"]?.stringValue ?? $0["type"]?.stringValue
                }
                let name = matcher.isEmpty ? event : "\(event) · \(matcher)"
                let described = redacted(commands.joined(separator: "; "))
                result.append(ConfigItem(
                    id: itemID(scope: scope, kind: .hook, key: "\(event)/\(groupIndex)/\(matcher)"),
                    kind: .hook, name: name, scope: scope, url: url,
                    detail: summary(described, limit: 80), bytes: 0,
                    modified: modificationDate(url),
                    contentHash: hash(of: "\(name)|\(described)"), isEnabled: nil))
            }
        }
        return result
    }

    // MARK: Settings

    /// Keys whose values are enumerations or flags rather than data, and are therefore safe
    /// to print. Every other key is reported by name and shape only.
    static let valueSafeSettingKeys: Set<String> = [
        "model", "effortLevel", "outputStyle", "cleanupPeriodDays", "includeCoAuthoredBy",
        "forceLoginMethod", "disableAllHooks", "autoUpdates", "installMethod", "theme",
        "spinnerTipsEnabled", "alwaysThinkingEnabled", "attribution",
    ]

    static func settingItems(_ settings: JSONValue, url: URL, scope: ConfigScope,
                             prefix: String = "") -> [ConfigItem] {
        guard let object = settings.objectValue else { return [] }
        let modified = modificationDate(url)
        var result: [ConfigItem] = []

        func add(_ name: String, _ detail: String, _ fingerprint: String) {
            result.append(ConfigItem(
                id: itemID(scope: scope, kind: .setting, key: "\(url.lastPathComponent)/\(name)"),
                kind: .setting, name: name, scope: scope, url: url,
                detail: summary(detail), bytes: 0, modified: modified,
                contentHash: hash(of: "\(name)|\(fingerprint)"), isEnabled: nil))
        }

        for (key, value) in object.orderedPairs {
            let name = prefix + key
            switch key {
            case "hooks":
                continue  // Surfaced individually as `.hook` items.
            case "permissions":
                guard let permissions = value.objectValue else { continue }
                if let mode = permissions["defaultMode"]?.stringValue {
                    add("\(name).defaultMode", mode, mode)
                }
                for list in ["allow", "deny", "ask"] {
                    guard let rules = permissions[list]?.arrayValue, !rules.isEmpty else { continue }
                    // Permission rules are tool patterns, not credentials, but they are also
                    // long and numerous; the count is the reviewable fact.
                    add("\(name).\(list)", "\(rules.count) rule\(rules.count == 1 ? "" : "s")",
                        String(rules.count))
                }
            case "env":
                guard let env = value.objectValue else { continue }
                for envKey in env.keys.sorted() {
                    add("env.\(envKey)", "value hidden", envKey)
                }
            case "enabledPlugins":
                continue  // Surfaced individually as `.plugin` items.
            default:
                if valueSafeSettingKeys.contains(key), let text = scalarText(value) {
                    add(name, text, text)
                } else {
                    let shape = shapeDescription(value)
                    add(name, shape, shape)
                }
            }
        }
        return result
    }

    /// A value's shape, never its content.
    static func shapeDescription(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "on" : "off"
        case .int, .double: return "number set"
        case .string: return "set"
        case .array(let items): return "\(items.count) entr\(items.count == 1 ? "y" : "ies")"
        case .object(let o): return "\(o.count) key\(o.count == 1 ? "" : "s")"
        }
    }

    static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "on" : "off"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    // MARK: Plugins

    static func claudeCodePluginItems(configDir: URL, settings: JSONValue,
                                      scope: ConfigScope) -> [ConfigItem] {
        let installedURL = configDir
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("installed_plugins.json")
        let installed = json(at: installedURL)["plugins"]?.objectValue
        let enabled = settings["enabledPlugins"]?.objectValue

        var names: [String] = []
        var seen = Set<String>()
        for key in (installed?.keys ?? []) + (enabled?.keys ?? []) where seen.insert(key).inserted {
            names.append(key)
        }

        var result: [ConfigItem] = []
        for key in names.sorted() {
            let entry = installed?[key]?.arrayValue?.first
            let version = entry?["version"]?.stringValue
            let installPath = entry?["installPath"]?.stringValue
            let installURL = installPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

            var pieces: [String] = []
            if let version, version != "unknown" { pieces.append(version) }
            if installURL == nil { pieces.append("not installed") }

            result.append(ConfigItem(
                id: itemID(scope: scope, kind: .plugin, key: key),
                kind: .plugin, name: key, scope: scope, url: installURL,
                detail: summary(pieces.joined(separator: " · ")),
                bytes: installURL.map { footprint(of: $0) } ?? 0,
                modified: installURL.flatMap { modificationDate($0) } ?? modificationDate(installedURL),
                contentHash: hash(of: "\(key)|\(version ?? "")"),
                isEnabled: enabled?[key]?.boolValue))

            // A plugin's own skills, agents and commands are configuration the user has, even
            // though they did not write them — an install that has a skill another install
            // lacks is exactly what a comparison is for.
            if let installURL {
                result.append(contentsOf: skillItems(
                    root: installURL.appendingPathComponent("skills", isDirectory: true),
                    scope: scope, source: key))
                result.append(contentsOf: definitionItems(
                    root: installURL.appendingPathComponent("agents", isDirectory: true),
                    kind: .subagent, scope: scope, source: key))
                result.append(contentsOf: definitionItems(
                    root: installURL.appendingPathComponent("commands", isDirectory: true),
                    kind: .command, scope: scope, source: key))
            }
        }
        return result
    }

    static func desktopPluginItems(_ settings: JSONValue, url: URL,
                                   scope: ConfigScope) -> [ConfigItem] {
        var result: [ConfigItem] = []
        let modified = modificationDate(url)

        if let enabled = settings["enabledPlugins"]?.objectValue {
            for (key, value) in enabled.orderedPairs {
                result.append(ConfigItem(
                    id: itemID(scope: scope, kind: .plugin, key: key),
                    kind: .plugin, name: key, scope: scope, url: nil,
                    detail: "cowork plugin", bytes: 0, modified: modified,
                    contentHash: hash(of: key), isEnabled: value.boolValue))
            }
        }

        let marketplaces = settings["marketplaces"]
        let names: [String]
        if let object = marketplaces?.objectValue {
            names = object.keys
        } else if let list = marketplaces?.arrayValue {
            names = list.compactMap { $0.stringValue ?? $0["name"]?.stringValue }
        } else {
            names = []
        }
        for name in names {
            result.append(ConfigItem(
                id: itemID(scope: scope, kind: .plugin, key: "marketplace/\(name)"),
                kind: .plugin, name: name, scope: scope, url: nil,
                detail: "marketplace", bytes: 0, modified: modified,
                contentHash: hash(of: "marketplace/\(name)"), isEnabled: nil))
        }
        return result
    }
}

// MARK: - Shared helpers

extension ConfigInventory {

    static func homeJSONURL() -> URL {
        Discovery.homeDirectory().appendingPathComponent(".claude.json")
    }

    /// Parse a JSON file, answering `.null` for anything missing or malformed.
    ///
    /// Every caller treats an unparsable file as "this scope has no such configuration",
    /// which is what the applications themselves do: a settings file with a trailing comma
    /// disables the settings, it does not disable Claude.
    static func json(at url: URL) -> JSONValue {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONValue.parse(data)
        else { return .null }
        return value
    }

    static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Whether a path is a directory, following symbolic links.
    ///
    /// `.isDirectoryKey` describes the link itself, not its target, so a skill installed as
    /// `skills/foo -> ~/.agents/skills/foo` — which is how anyone who keeps their skills in a
    /// repository installs them — answers `false` and disappears from the inventory. Recursion
    /// through a link is bounded by the depth limits at each call site rather than by a visited
    /// set, since these trees are shallow and a cycle costs six `contentsOfDirectory` calls.
    static func isDirectoryFollowingLinks(_ url: URL) -> Bool {
        Discovery.isDirectory(url) || Discovery.isDirectory(url.resolvingSymlinksInPath())
    }

    static func visibleDirectories(_ root: URL) -> [URL] {
        guard isDirectoryFollowingLinks(root) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return entries.filter { isDirectoryFollowingLinks($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `*.md` files under `root`, each with its path relative to `root`.
    ///
    /// The relative path is accumulated during the walk rather than recovered afterwards by
    /// stripping a prefix. `contentsOfDirectory` hands back paths in whatever form the
    /// filesystem canonicalizes to — `/private/var/…` for a URL built from `/var/…` — so a
    /// prefix comparison against the root silently fails and every namespaced command
    /// collapses to its bare filename.
    static func markdownFiles(under root: URL, prefix: String = "",
                              depth: Int = 0) -> [(url: URL, relative: String)] {
        guard depth < 4 else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        var result: [(url: URL, relative: String)] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if isDirectoryFollowingLinks(entry) {
                result.append(contentsOf: markdownFiles(under: entry, prefix: prefix + name + "/",
                                                        depth: depth + 1))
            } else if entry.pathExtension.lowercased() == "md" {
                result.append((entry, prefix + name))
            }
        }
        return result
    }

    static func itemID(scope: ConfigScope, kind: ConfigKind, key: String) -> String {
        "\(scope.id)|\(kind.rawValue)|\(key)"
    }

    /// Flatten to one line and cap the length.
    static func summary(_ text: String, limit: Int = 140) -> String? {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    /// Blank out anything shaped like an inline credential.
    ///
    /// Hook commands are shell, and shell is where a token gets pasted inline. The truncated
    /// command is worth showing; the value after `TOKEN=` never is.
    static func redacted(_ text: String) -> String {
        let markers = ["key", "token", "secret", "password", "passwd", "apikey", "api_key",
                       "auth", "credential", "bearer"]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "=" || character == ":" {
                let head = out.lowercased()
                let trailingWord = head.reversed().prefix { $0.isLetter || $0 == "_" || $0 == "-" }
                let word = String(String(trailingWord).reversed())
                if markers.contains(where: { word.hasSuffix($0) }) {
                    out.append(character)
                    out.append("‹hidden›")
                    // Drop the value: everything up to the next whitespace.
                    index = text.index(after: index)
                    while index < text.endIndex, !text[index].isWhitespace {
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            out.append(character)
            index = text.index(after: index)
        }
        return out
    }

    // MARK: Fingerprints

    static func hash(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    static func digest(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    /// Fingerprint a directory from its primary file plus the shape of everything else.
    ///
    /// Hashing every byte of a skill would mean reading its whole reference tree — and for an
    /// extension bundle, its `node_modules`. The primary file is hashed in full because that
    /// is the part people edit; the rest contributes its relative path and size, which changes
    /// whenever a file is added, removed, or rewritten to a different length.
    static func directoryDigest(_ root: URL, primary: URL?) -> String? {
        guard isDirectoryFollowingLinks(root) else { return nil }
        var material = primary.flatMap { digest(fileAt: $0) } ?? ""
        for (path, size) in inventory(of: root) {
            material += "\n\(path)\t\(size)"
        }
        return hash(of: material)
    }

    /// Relative path and size of every regular file under `root`, capped.
    static let footprintFileLimit = 2000

    static let skippedSubtrees: Set<String> = ["node_modules", ".git", ".build", "dist"]

    static func inventory(of root: URL) -> [(String, Int64)] {
        // The path-based enumerator yields paths relative to its root, which is exactly what
        // the fingerprint needs and avoids reconstructing them from absolute paths that the
        // filesystem may have canonicalized differently. Resolving the root first matters
        // because the enumerator will not descend through a symbolic link, and a symlinked
        // skill would otherwise measure and fingerprint as empty.
        let resolved = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(atPath: resolved.path) else {
            return []
        }

        var result: [(String, Int64)] = []
        for case let relative as String in enumerator {
            // A Desktop extension bundle ships its whole dependency tree. Walking it costs
            // more than the rest of the inventory combined and tells us nothing: what
            // identifies an extension is its manifest, which is hashed in full.
            if skippedSubtrees.contains((relative as NSString).lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { continue }
            result.append((relative, size.int64Value))
            if result.count >= footprintFileLimit { break }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    static func footprint(of url: URL) -> Int64 {
        guard isDirectoryFollowingLinks(url) else { return Discovery.fileSize(url) }
        return inventory(of: url).reduce(0) { $0 + $1.1 }
    }
}

extension URL {
    var isReadableFile: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
}
