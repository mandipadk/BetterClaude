import Foundation
import Testing

@testable import CoworkKit

// MARK: - Front matter

/// The front-matter reader decides what a skill is *called*, which decides what it lines up
/// against in a comparison. A reader that is merely "usually right" produces a diff that
/// silently pairs the wrong two files, so the malformed and adversarial shapes are tested
/// alongside the happy one.
@Suite("FrontMatter")
struct FrontMatterTests {

    @Test("Name and description are read from a normal block")
    func normal() {
        let text = """
            ---
            name: code-review
            description: Reviews a diff before it lands.
            ---

            # Code review
            """
        let matter = FrontMatter.parse(text)
        #expect(matter["name"] == "code-review")
        #expect(matter["description"] == "Reviews a diff before it lands.")
    }

    @Test("A file with no front matter yields nothing")
    func absent() {
        #expect(FrontMatter.parse("# Just a heading\n\nname: not-front-matter\n").isEmpty)
        #expect(FrontMatter.parse("").isEmpty)
        #expect(FrontMatter.parse("\n\n").isEmpty)
    }

    @Test("A block that is opened and never closed yields nothing")
    func unterminated() {
        let text = """
            ---
            name: half-written
            description: the delimiter below is missing

            # Body
            """
        #expect(FrontMatter.parse(text).isEmpty)
    }

    @Test("Lines without a colon, and stray delimiters, are skipped rather than fatal")
    func malformed() {
        let text = """
            ---
            name: survivor
            this line has no colon at all
            # a comment: with a colon in it
            : leading colon
            description: still read
            ---
            """
        let matter = FrontMatter.parse(text)
        #expect(matter["name"] == "survivor")
        #expect(matter["description"] == "still read")
        #expect(matter["#a comment"] == nil)
    }

    @Test("A nested mapping cannot replace a top-level key")
    func nestedKeysDoNotLeak() {
        // `check/SKILL.md` really does carry a `metadata:` block. If its indented keys were
        // flattened, every skill with a nested `name:` would be renamed by its own metadata.
        let text = """
            ---
            name: check
            metadata:
              name: WRONG
              version: "3.5.0"
            tools:
              - Read
              - Edit
            description: Reviews the diff.
            ---
            """
        let matter = FrontMatter.parse(text)
        #expect(matter["name"] == "check")
        #expect(matter["version"] == nil)
        #expect(matter["description"] == "Reviews the diff.")
        // A sequence has no scalar value, so the key is dropped rather than invented.
        #expect(matter["tools"] == nil)
    }

    @Test("Quotes are stripped and block scalars are folded to one line")
    func scalars() {
        let text = """
            ---
            name: "quoted-name"
            other: 'single'
            description: >
              A folded description
              spanning two lines.
            model: sonnet
            ---
            """
        let matter = FrontMatter.parse(text)
        #expect(matter["name"] == "quoted-name")
        #expect(matter["other"] == "single")
        #expect(matter["description"] == "A folded description spanning two lines.")
        #expect(matter["model"] == "sonnet")
    }

    @Test("Unicode names, values and CRLF line endings survive intact")
    func unicode() {
        let text = "\u{FEFF}---\r\nname: 日本語-スキル\r\n"
            + "description: Grüße — a description with an em dash and 中文.\r\n---\r\nbody\r\n"
        let matter = FrontMatter.parse(text)
        #expect(matter["name"] == "日本語-スキル")
        #expect(matter["description"] == "Grüße — a description with an em dash and 中文.")
    }

    @Test("The block must be the very first thing in the file")
    func mustLeadTheFile() {
        let text = """
            # Heading first

            ---
            name: too-late
            ---
            """
        #expect(FrontMatter.parse(text).isEmpty)
    }
}

// MARK: - MCP inspection

/// The one place in this feature where a mistake is not a cosmetic bug. An MCP server
/// configuration is where people keep API tokens, and an inventory that prints one into a
/// window — or into a fingerprint — has done real harm.
@Suite("MCP inspection")
struct MCPInspectionTests {

    private let tokenValue = "sk-live-9f2c4d8e1a7b3c5d6e0f"
    private let headerValue = "Bearer abcdef0123456789abcdef"

    private func remoteServer() throws -> JSONValue {
        try JSONValue.parse("""
            {
              "type": "http",
              "url": "https://mcp.example.com/v1/sse?token=\(tokenValue)",
              "headers": { "Authorization": "\(headerValue)", "X-Org": "acme-internal-99" }
            }
            """)
    }

    private func localServer() throws -> JSONValue {
        try JSONValue.parse("""
            {
              "command": "/opt/homebrew/bin/npx",
              "args": ["-y", "some-server", "--api-key=\(tokenValue)"],
              "env": { "GITHUB_TOKEN": "\(tokenValue)", "HOME_OVERRIDE": "/Users/someone" }
            }
            """)
    }

    @Test("Header and env keys are reported, values never are")
    func keyNamesOnly() throws {
        let remote = ConfigInventory.inspectMCPServer(name: "docs", config: try remoteServer())
        #expect(remote.headerKeyNames == ["Authorization", "X-Org"])
        #expect(remote.detail.contains("Authorization"))
        #expect(!remote.detail.contains(headerValue))
        #expect(!remote.detail.contains("acme-internal-99"))

        let local = ConfigInventory.inspectMCPServer(name: "gh", config: try localServer())
        #expect(local.envKeyNames == ["GITHUB_TOKEN", "HOME_OVERRIDE"])
        #expect(local.detail.contains("GITHUB_TOKEN"))
        #expect(!local.detail.contains(tokenValue))
        #expect(!local.detail.contains("/Users/someone"))
    }

    @Test("Only the host of a URL survives; the query string is dropped")
    func urlIsReducedToItsHost() throws {
        let remote = ConfigInventory.inspectMCPServer(name: "docs", config: try remoteServer())
        #expect(remote.transport == "http")
        #expect(remote.host == "mcp.example.com")
        #expect(!remote.detail.contains("token="))
        #expect(!remote.detail.contains("/v1/sse"))
        #expect(!remote.fingerprintSource.contains(tokenValue))
    }

    @Test("Only the executable name of a stdio server survives; arguments are dropped")
    func commandIsReducedToItsName() throws {
        let local = ConfigInventory.inspectMCPServer(name: "gh", config: try localServer())
        #expect(local.transport == "stdio")
        #expect(local.commandName == "npx")
        #expect(!local.detail.contains("--api-key"))
        #expect(!local.detail.contains("some-server"))
        #expect(!local.fingerprintSource.contains(tokenValue))
    }

    @Test("Nothing surfaced by a full scope walk contains a configured secret")
    func endToEndOverAScope() throws {
        try ConfigFixture.withScratch { root in
            try ConfigFixture.write("""
                { "mcpServers": {
                    "docs": { "type": "http",
                              "url": "https://mcp.example.com/v1?token=\(tokenValue)",
                              "headers": { "Authorization": "\(headerValue)" } },
                    "gh": { "command": "npx",
                            "env": { "GITHUB_TOKEN": "\(tokenValue)" } } } }
                """, to: root.appendingPathComponent(".mcp.json"))
            try ConfigFixture.write("""
                { "env": { "SECRET_KEY": "\(tokenValue)" },
                  "apiKeyHelper": "\(tokenValue)",
                  "hooks": { "PreToolUse": [ { "matcher": "Bash",
                      "hooks": [ { "type": "command",
                                   "command": "MY_TOKEN=\(tokenValue) /usr/local/bin/notify" } ] } ] } }
                """, to: root.appendingPathComponent(".claude/settings.json"))

            let scope = ConfigScope.claudeCodeProject(root)
            let items = try ConfigInventory.items(in: scope)
            let surfaced = (items.compactMap(\.detail) + items.map(\.name)
                + items.compactMap(\.contentHash) + items.map(\.id)).joined(separator: "\u{1}")

            #expect(!surfaced.contains(tokenValue))
            #expect(!surfaced.contains(headerValue))
            // The key names are the point of the feature and must still be there.
            #expect(surfaced.contains("GITHUB_TOKEN"))
            #expect(surfaced.contains("SECRET_KEY"))
            #expect(surfaced.contains("Authorization"))
            // A hook command is shown, with the inline assignment blanked out.
            let hook = try #require(items.first { $0.kind == .hook })
            #expect((hook.detail ?? "").contains("MY_TOKEN="))
            #expect(!(hook.detail ?? "").contains(tokenValue))
            // A value-bearing top-level setting is reported by name and shape only.
            let helper = try #require(items.first { $0.kind == .setting && $0.name == "apiKeyHelper" })
            #expect(helper.detail == "set")
        }
    }
}

// MARK: - Inventory

@Suite("ConfigInventory")
struct ConfigInventoryTests {

    @Test("A project scope finds its skills, agents, commands and memory")
    func projectScopeWalk() throws {
        try ConfigFixture.withScratch { root in
            try ConfigFixture.makeSkill(in: root.appendingPathComponent(".claude/skills/alpha"),
                                  name: "alpha", description: "First skill.", body: "one")
            // A namespaced pack: `skills/pack/inner/SKILL.md`.
            try ConfigFixture.makeSkill(in: root.appendingPathComponent(".claude/skills/pack/inner"),
                                  name: "inner", description: "Nested.", body: "two")
            try ConfigFixture.write("---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nbody",
                              to: root.appendingPathComponent(".claude/agents/reviewer.md"))
            try ConfigFixture.write("Run the thing.",
                              to: root.appendingPathComponent(".claude/commands/git/sync.md"))
            try ConfigFixture.write("# Project memory\nline two\n",
                              to: root.appendingPathComponent("CLAUDE.md"))

            let items = try ConfigInventory.items(in: .claudeCodeProject(root))
            #expect(Set(items.filter { $0.kind == .skill }.map(\.name)) == ["alpha", "inner"])
            #expect(items.filter { $0.kind == .subagent }.map(\.name) == ["reviewer"])
            // No front matter, so the command is named by its path inside `commands/`.
            #expect(items.filter { $0.kind == .command }.map(\.name) == ["git:sync"])
            #expect(items.filter { $0.kind == .memory }.map(\.name) == ["CLAUDE.md"])
            #expect(items.allSatisfy { $0.scope == .claudeCodeProject(root) })
            #expect(Set(items.map(\.id)).count == items.count)
        }
    }

    @Test("Malformed and missing files remove one entry rather than aborting the walk")
    func toleratesJunk() throws {
        try ConfigFixture.withScratch { root in
            try ConfigFixture.write("{ this is not json,,, ",
                              to: root.appendingPathComponent(".claude/settings.json"))
            try ConfigFixture.write("{ \"mcpServers\": [1, 2, 3] }",
                              to: root.appendingPathComponent(".mcp.json"))
            try ConfigFixture.makeSkill(in: root.appendingPathComponent(".claude/skills/ok"),
                                  name: "ok", description: "Fine.", body: "x")
            // A directory that looks like a skill but has no SKILL.md.
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".claude/skills/empty"),
                withIntermediateDirectories: true)

            let items = try ConfigInventory.items(in: .claudeCodeProject(root))
            #expect(items.filter { $0.kind == .skill }.map(\.name) == ["ok"])
            #expect(items.filter { $0.kind == .mcpServer }.isEmpty)
            #expect(items.filter { $0.kind == .setting }.isEmpty)
        }
    }

    @Test("A skill installed as a symbolic link is still found")
    func followsSymlinkedSkills() throws {
        try ConfigFixture.withScratch { root in
            let real = root.appendingPathComponent("elsewhere/linked")
            try ConfigFixture.makeSkill(in: real, name: "linked", description: "Kept in a repo.",
                                  body: "z")
            let skills = root.appendingPathComponent(".claude/skills")
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: skills.appendingPathComponent("linked"), withDestinationURL: real)

            let items = try ConfigInventory.items(in: .claudeCodeProject(root))
            let skill = try #require(items.first { $0.kind == .skill })
            #expect(skill.name == "linked")
            #expect(skill.bytes > 0)
            #expect(skill.contentHash != nil)
        }
    }
}

// MARK: - Diff

@Suite("ConfigDiff")
struct ConfigDiffTests {

    private let left = ConfigScope.claudeCodeProject(URL(fileURLWithPath: "/tmp/left"))
    private let right = ConfigScope.claudeCodeProject(URL(fileURLWithPath: "/tmp/right"))

    private func item(_ kind: ConfigKind, _ name: String, hash: String?,
                      in scope: ConfigScope) -> ConfigItem {
        ConfigItem(id: "\(scope.id)|\(kind.rawValue)|\(name)", kind: kind, name: name,
                   scope: scope, url: nil, detail: nil, bytes: 0, modified: nil,
                   contentHash: hash, isEnabled: nil)
    }

    @Test("Items match on kind and name, and produce all four statuses")
    func fourStatuses() {
        let leftItems = [
            item(.skill, "shared", hash: "aaa", in: left),
            item(.skill, "edited", hash: "111", in: left),
            item(.skill, "mine-only", hash: "bbb", in: left),
            item(.command, "shared", hash: "ccc", in: left),
        ]
        let rightItems = [
            item(.skill, "shared", hash: "aaa", in: right),
            item(.skill, "edited", hash: "222", in: right),
            item(.skill, "theirs-only", hash: "ddd", in: right),
            item(.command, "shared", hash: "eee", in: right),
        ]

        let comparison = ConfigDiff.compare(left, leftItems, right, rightItems)
        func status(_ kind: ConfigKind, _ name: String) -> ConfigComparison.Status? {
            comparison.rows.first { $0.kind == kind && $0.name == name }?.status
        }

        #expect(status(.skill, "shared") == .same)
        #expect(status(.skill, "edited") == .different)
        #expect(status(.skill, "mine-only") == .onlyLeft)
        #expect(status(.skill, "theirs-only") == .onlyRight)
        // Same name, different kind: a command named `shared` is not the skill named `shared`.
        #expect(status(.command, "shared") == .different)

        let summary = comparison.summary
        #expect(summary.same == 1)
        #expect(summary.different == 2)
        #expect(summary.onlyLeft == 1)
        #expect(summary.onlyRight == 1)
        #expect(comparison.rows.count == 5)
    }

    @Test("A missing fingerprint on either side is reported as same, never as different")
    func missingHashesDoNotInventDifferences() {
        let comparison = ConfigDiff.compare(
            left, [item(.mcpServer, "docs", hash: nil, in: left)],
            right, [item(.mcpServer, "docs", hash: "abc", in: right)])
        #expect(comparison.rows.map(\.status) == [.same])
    }

    @Test("Two items with the same kind and name in one scope both get a row")
    func duplicatesArePairedNotCollapsed() {
        let leftItems = [
            item(.skill, "twin", hash: "one", in: left),
            item(.skill, "twin", hash: "two", in: left),
        ]
        let comparison = ConfigDiff.compare(left, leftItems, right,
                                            [item(.skill, "twin", hash: "one", in: right)])
        #expect(comparison.rows.count == 2)
        #expect(comparison.summary.same == 1)
        #expect(comparison.summary.onlyLeft == 1)
        #expect(Set(comparison.rows.map(\.id)).count == 2)
    }

    @Test("Rows are grouped by kind and alphabetical within a kind")
    func ordering() {
        let comparison = ConfigDiff.compare(
            left,
            [item(.setting, "model", hash: "1", in: left),
             item(.skill, "zebra", hash: "2", in: left),
             item(.skill, "apple", hash: "3", in: left)],
            right, [])
        #expect(comparison.rows.map(\.name) == ["apple", "zebra", "model"])
    }

    @Test("Comparing two real directories reports the four statuses from disk")
    func acrossRealDirectories() throws {
        try ConfigFixture.withScratch { a in
            try ConfigFixture.withScratch { b in
                try ConfigFixture.makeSkill(in: a.appendingPathComponent(".claude/skills/shared"),
                                      name: "shared", description: "Same.", body: "identical")
                try ConfigFixture.makeSkill(in: b.appendingPathComponent(".claude/skills/shared"),
                                      name: "shared", description: "Same.", body: "identical")
                try ConfigFixture.makeSkill(in: a.appendingPathComponent(".claude/skills/edited"),
                                      name: "edited", description: "Drifted.", body: "version one")
                try ConfigFixture.makeSkill(in: b.appendingPathComponent(".claude/skills/edited"),
                                      name: "edited", description: "Drifted.", body: "version two")
                try ConfigFixture.makeSkill(in: a.appendingPathComponent(".claude/skills/mine"),
                                      name: "mine", description: "Only here.", body: "x")
                try ConfigFixture.makeSkill(in: b.appendingPathComponent(".claude/skills/theirs"),
                                      name: "theirs", description: "Only there.", body: "y")

                let comparison = try ConfigDiff.compare(.claudeCodeProject(a),
                                                        .claudeCodeProject(b))
                func status(_ name: String) -> ConfigComparison.Status? {
                    comparison.rows.first { $0.name == name }?.status
                }
                #expect(status("shared") == .same)
                #expect(status("edited") == .different)
                #expect(status("mine") == .onlyLeft)
                #expect(status("theirs") == .onlyRight)

                let summary = comparison.summary
                #expect((summary.same, summary.different, summary.onlyLeft, summary.onlyRight)
                        == (1, 1, 1, 1))
            }
        }
    }
}

// MARK: - Fixtures

/// Synthetic stores only. Nothing in this file reads or writes the real configuration.
enum ConfigFixture {

    static func withScratch(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The temporary directory is a symlink on macOS, and a scope keyed by the unresolved
        // path would not match the paths the walk produces.
        try body(root.resolvingSymlinksInPath())
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    static func makeSkill(in directory: URL, name: String, description: String,
                          body: String) throws {
        try write("---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n",
                  to: directory.appendingPathComponent("SKILL.md"))
    }
}
