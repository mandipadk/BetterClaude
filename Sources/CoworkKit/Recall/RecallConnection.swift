import Foundation

/// Adds Better Claude's history server to a Claude's tools, or takes it out again.
///
/// Claude Code is changed through its own `claude mcp` command, which owns the state file it
/// lives in. A Claude Desktop install reads `claude_desktop_config.json` in its data folder;
/// that file is backed up before it's changed, and only the one entry named ``serverName`` is
/// ever added or removed.
public enum RecallConnection {

    public static let serverName = "better-claude"

    public enum Target: Sendable, Hashable {
        case claudeCode(configDir: URL)
        case desktop(dataRoot: URL)
    }

    public enum Failure: Error, CustomStringConvertible {
        case noClaudeCommand(manual: String)
        case commandFailed(String)

        public var description: String {
            switch self {
            case .noClaudeCommand(let manual):
                return "Couldn't find the claude command. Run this in Terminal instead: \(manual)"
            case .commandFailed(let output):
                return "Claude Code said: \(output)"
            }
        }
    }

    public static func target(for install: Install, paths: HostPaths = .current) -> Target? {
        switch install.kind {
        case .claudeCode: return .claudeCode(configDir: paths.claudeCodeConfigDir)
        case .desktop, .parallex: return .desktop(dataRoot: install.dataRoot)
        case .science, .external: return nil
        }
    }

    // MARK: Reading

    /// The server entry as registered now, if it is: its command and arguments.
    public static func registration(_ target: Target, paths: HostPaths = .current) -> (command: String, arguments: [String])? {
        let url: URL
        let servers: JSONValue?
        switch target {
        case .claudeCode(let configDir):
            url = claudeCodeState(configDir: configDir, paths: paths)
            servers = (try? JSONValue.parse(Data(contentsOf: url)))?["mcpServers"]
        case .desktop(let dataRoot):
            url = desktopConfig(dataRoot)
            servers = (try? JSONValue.parse(Data(contentsOf: url)))?["mcpServers"]
        }
        guard let entry = servers?[serverName], let command = entry["command"]?.stringValue else { return nil }
        return (command, entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    public static func isConnected(_ target: Target, paths: HostPaths = .current) -> Bool {
        registration(target, paths: paths) != nil
    }

    static func claudeCodeState(configDir: URL, paths: HostPaths) -> URL {
        configDir.standardizedFileURL == paths.home.appendingPathComponent(".claude").standardizedFileURL
            ? paths.home.appendingPathComponent(".claude.json")
            : configDir.appendingPathComponent(".claude.json")
    }

    static func desktopConfig(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("claude_desktop_config.json")
    }

    // MARK: Changing

    public static func connect(_ target: Target, server: URL, account: String, paths: HostPaths = .current) throws {
        let arguments = ["--account", account]
        switch target {
        case .claudeCode(let configDir):
            if isConnected(target, paths: paths) { try runClaude(["mcp", "remove", "--scope", "user", serverName], configDir: configDir, paths: paths) }
            try runClaude(["mcp", "add", "--scope", "user", serverName, "--", server.path] + arguments,
                          configDir: configDir, paths: paths)
        case .desktop(let dataRoot):
            try editDesktopConfig(dataRoot, paths: paths) { servers in
                servers[serverName] = .object(JSONObject([
                    ("command", .string(server.path)),
                    ("args", .array(arguments.map(JSONValue.string))),
                ]))
            }
        }
    }

    public static func disconnect(_ target: Target, paths: HostPaths = .current) throws {
        guard isConnected(target, paths: paths) else { return }
        switch target {
        case .claudeCode(let configDir):
            try runClaude(["mcp", "remove", "--scope", "user", serverName], configDir: configDir, paths: paths)
        case .desktop(let dataRoot):
            try editDesktopConfig(dataRoot, paths: paths) { servers in servers[serverName] = nil }
        }
    }

    static func editDesktopConfig(_ dataRoot: URL, paths: HostPaths, _ change: (inout JSONObject) -> Void) throws {
        let url = desktopConfig(dataRoot)
        var config: JSONValue = .object(JSONObject())
        if FileManager.default.fileExists(atPath: url.path) {
            config = try JSONValue.parse(try Data(contentsOf: url))
            guard case .object = config else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            try backUp(url, label: dataRoot.lastPathComponent, paths: paths)
        }
        var servers = config["mcpServers"]?.objectValue ?? JSONObject()
        change(&servers)
        config["mcpServers"] = servers.count == 0 ? nil : .object(servers)
        try AtomicWrite.write(config.serializedPretty(), to: url)
    }

    static func backUp(_ url: URL, label: String, paths: HostPaths) throws {
        let dir = paths.betterClaudeSupport.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(label)-\(stamp).json")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
    }

    // MARK: The claude command

    /// Where the `claude` command usually lives; a GUI app doesn't get the shell's PATH.
    public static func claudeCommand(paths: HostPaths = .current) -> URL? {
        let home = paths.home.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude",
                          "\(home)/.bun/bin/claude"]
        return candidates.lazy.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func runClaude(_ arguments: [String], configDir: URL, paths: HostPaths) throws {
        let manual = "claude " + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        guard let claude = claudeCommand(paths: paths) else { throw Failure.noClaudeCommand(manual: manual) }
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = paths.home.path
        if configDir.standardizedFileURL != paths.home.appendingPathComponent(".claude").standardizedFileURL {
            environment["CLAUDE_CONFIG_DIR"] = configDir.path
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw Failure.commandFailed(text.isEmpty ? "exit \(process.terminationStatus)" : text) }
    }
}
