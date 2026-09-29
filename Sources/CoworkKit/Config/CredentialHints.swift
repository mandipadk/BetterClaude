import Foundation

/// Settings that hold what looks like a credential in plain text.
///
/// Only the names of the settings are ever returned, never their values: this exists to tell
/// a person where a key is sitting, and a list that printed it would be the leak it warns
/// about.
public enum CredentialHints {

    public struct Hint: Sendable, Hashable {
        /// The setting's name, like `SEARCH_API_KEY`.
        public let name: String
        /// The file it is in.
        public let file: URL
    }

    static let credentialWords = ["key", "token", "secret", "password", "passwd", "credential"]

    /// Credential-shaped settings for one install.
    public static func hints(for install: Install) -> [Hint] {
        switch install.kind {
        case .claudeCode:
            let settings = install.dataRoot.appendingPathComponent("settings.json")
            return settingsHints(at: settings)
        case .desktop, .parallex:
            return mcpHints(at: install.dataRoot.appendingPathComponent("claude_desktop_config.json"))
        case .science, .external:
            return []
        }
    }

    /// Top-level settings and `env` entries of a Claude Code `settings.json`.
    static func settingsHints(at url: URL) -> [Hint] {
        guard let data = try? Data(contentsOf: url), let root = try? JSONValue.parse(data),
              let object = root.objectValue else { return [] }
        var names: [String] = []
        for (key, value) in object.orderedPairs where looksLikeCredential(key, value) {
            names.append(key)
        }
        for (key, value) in object["env"]?.objectValue?.orderedPairs ?? [] where looksLikeCredential(key, value) {
            names.append(key)
        }
        return names.map { Hint(name: $0, file: url) }
    }

    /// `env` entries of each MCP server in a Claude Desktop config.
    static func mcpHints(at url: URL) -> [Hint] {
        guard let data = try? Data(contentsOf: url), let root = try? JSONValue.parse(data),
              let servers = root["mcpServers"]?.objectValue else { return [] }
        var hints: [Hint] = []
        for (_, server) in servers.orderedPairs {
            for (key, value) in server["env"]?.objectValue?.orderedPairs ?? [] where looksLikeCredential(key, value) {
                hints.append(Hint(name: key, file: url))
            }
        }
        return hints
    }

    /// A name that says it is a secret, holding a non-empty literal. A reference such as
    /// `${KEY}` or `$KEY` points at the environment rather than holding the value.
    static func looksLikeCredential(_ name: String, _ value: JSONValue) -> Bool {
        let lowered = name.lowercased()
        guard credentialWords.contains(where: { lowered.contains($0) }),
              let text = value.stringValue?.trimmingCharacters(in: .whitespaces),
              text.count >= 8, !text.hasPrefix("$") else { return false }
        return true
    }
}
