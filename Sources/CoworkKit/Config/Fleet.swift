import Foundation

/// Setting one Claude up like another: copying an MCP server from any install into a Claude
/// Desktop install.
///
/// The entry is copied as it is, keys in its environment included, into the target's
/// `claude_desktop_config.json`. The file is backed up first and the receipt lets History
/// put it back as it was.
public enum Fleet {

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case targetUnsupported
        case exists(String)
        case ownServer

        public var description: String {
            switch self {
            case .notFound(let name): return "Couldn't find \(name)'s settings to copy."
            case .targetUnsupported: return "Servers can be copied into a Claude Desktop install."
            case .exists(let name): return "It already has a server called \(name)."
            case .ownServer: return "Better Claude's history server is added from each install's page, so it reads the right account's history."
            }
        }
    }

    /// An MCP server's entry, as the install that has it keeps it.
    public static func serverEntry(named name: String, in install: Install, paths: HostPaths = .current) -> JSONValue? {
        switch install.kind {
        case .desktop, .parallex:
            let config = install.dataRoot.appendingPathComponent("claude_desktop_config.json")
            return (try? JSONValue.parse(Data(contentsOf: config)))?["mcpServers"]?[name]
        case .claudeCode:
            let state = RecallConnection.claudeCodeState(configDir: install.dataRoot, paths: paths)
            return (try? JSONValue.parse(Data(contentsOf: state)))?["mcpServers"]?[name]
        default:
            return nil
        }
    }

    public static func canReceiveServers(_ install: Install) -> Bool { install.isDesktop }

    /// Copies an MCP server into a Desktop install, with a receipt.
    @discardableResult
    public static func copyServer(named name: String, from source: Install, to target: Install,
                                  paths: HostPaths = .current) throws -> ImportReceipt {
        guard canReceiveServers(target) else { throw Failure.targetUnsupported }
        // Its registration names whose history it reads; copying it would cross the walls.
        guard name != RecallConnection.serverName else { throw Failure.ownServer }
        guard var entry = serverEntry(named: name, in: source, paths: paths) else { throw Failure.notFound(name) }
        guard serverEntry(named: name, in: target, paths: paths) == nil else { throw Failure.exists(name) }
        // Claude Code marks how it reaches a server; Desktop only runs local commands.
        if entry["type"]?.stringValue == "stdio" { entry["type"] = nil }
        guard entry["command"]?.stringValue != nil else { throw Failure.notFound(name) }

        let config = target.dataRoot.appendingPathComponent("claude_desktop_config.json")
        var receipt = ImportReceipt(direction: .fleet, destination: target.name)
        receipt.title = "MCP server \(name)"
        receipt.itemCount = 1
        let existed = FileManager.default.fileExists(atPath: config.path)
        if existed { try receipt.backUp(config, paths: paths) }
        try Undo.save(receipt)
        try RecallConnection.editDesktopConfig(target.dataRoot, paths: paths) { servers in servers[name] = entry }
        if existed { try receipt.recordModified(at: config) } else { try receipt.recordCreatedFile(at: config) }
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }
}
