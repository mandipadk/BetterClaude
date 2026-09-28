import CoworkKit
import Foundation

/// Builds a complete, synthetic Mac that reads exactly like a real one: Claude Desktop, a
/// Parallex copy of it signed into a second account, Claude Science, and Claude Code with a
/// handful of projects — every conversation, account and address invented.
///
/// It exists so the app can be exercised, tested and photographed without a single real
/// conversation on screen. Point the app at it with `BC_FIXTURE_ROOT` (debug builds only) and
/// it believes that folder is the whole machine.
public struct FixtureHome {
    public let root: URL
    public let now: Date
    /// Real apps whose icons the sample borrows, so screenshots show real product imagery.
    /// Missing apps are fine; the sample app just has no icon.
    public var iconDonors: [String: URL] = [
        "Claude": URL(fileURLWithPath: "/Applications/Claude.app"),
        "Claude Science": URL(fileURLWithPath: "/Applications/Claude Science.app"),
    ]

    public var paths: HostPaths { .fixture(at: root) }

    public init(root: URL, now: Date = Date()) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.now = now
    }

    public static let personalAccount = "5b1c2e0a-7d44-4c1e-9a53-1f0e8a6b2c11"
    public static let personalOrg = "8e2f6a31-0c5d-4b7e-a1f9-3d6c2b8e4f70"
    public static let workAccount = "c3a9d7e2-4f18-4a6b-8d2c-9e1f7b3a5d60"
    public static let workOrg = "1f7e3c95-2a6d-4e8b-b4c1-6d0a9f2e7b38"

    /// Writes the whole machine. Refuses to write into a folder that already has content, so
    /// it can never be pointed at a real home by mistake.
    public func make() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path),
           let existing = try? fm.contentsOfDirectory(atPath: root.path), !existing.isEmpty {
            throw FixtureError.notEmpty(root.path)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try makeApps()
        try makeDesktop(
            userData: paths.applicationSupport.appendingPathComponent("Claude", isDirectory: true),
            account: Self.personalAccount, org: Self.personalOrg,
            email: "alex@rivera.studio", name: "Alex Rivera",
            orgName: "alex@rivera.studio's Organization", plan: "claude_max",
            conversations: Script.personalCowork,
            codeTab: Script.personalCodeTab,
            mcp: ["filesystem": "npx -y @modelcontextprotocol/server-filesystem ~/Documents",
                  "calendar": "/usr/local/bin/calendar-mcp"])
        try makeParallexWork()
        try makeScience()
        try makeClaudeCode()
        try makeKept()
    }

    /// One conversation Claude Code has already deleted, still held by Better Claude.
    func makeKept() throws {
        let conversation = Script.alreadyDeleted
        let cwd = paths.home.appendingPathComponent(conversation.project ?? "Code").path
        let transcript = Transcriber(conversation: conversation, cwd: cwd,
                                     start: now.addingTimeInterval(-conversation.age))
        try writeClaudeCodeTranscript(transcript, cwd: cwd, id: conversation.cliId)
        let url = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(cwd), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        try HostPaths.$current.withValue(paths) {
            try Vault.keep(transcriptAt: url, title: conversation.title, sessionId: conversation.cliId,
                           projectPath: cwd, installID: "claude-code:\(paths.claudeCodeConfigDir.path)")
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Apps

    func makeApps() throws {
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        try makeBundle(at: apps.appendingPathComponent("Claude.app"),
                       identifier: Discovery.electronBundleIdentifier, name: "Claude",
                       executable: "Claude", donor: iconDonors["Claude"])
        try makeBundle(at: apps.appendingPathComponent("Claude Science.app"),
                       identifier: "com.anthropic.operon", name: "Claude Science",
                       executable: "Claude Science", donor: iconDonors["Claude Science"])
        try makeBundle(at: apps.appendingPathComponent("Parallex.app"),
                       identifier: "com.parallex.app", name: "Parallex",
                       executable: "Parallex", donor: nil)
    }

    func makeBundle(at url: URL, identifier: String, name: String, executable: String,
                    donor: URL?) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
        ]
        if let donor, let icon = Self.iconFile(inBundle: donor) {
            let target = resources.appendingPathComponent("AppIcon.icns")
            try? FileManager.default.copyItem(at: icon, to: target)
            info["CFBundleIconFile"] = "AppIcon"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        FileManager.default.createFile(atPath: macOS.appendingPathComponent(executable).path,
                                       contents: Data("#!/bin/sh\nexit 0\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    static func iconFile(inBundle bundle: URL) -> URL? {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              var name = plist["CFBundleIconFile"] as? String else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        let url = bundle.appendingPathComponent("Contents/Resources/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Claude Desktop

    func makeDesktop(userData: URL, account: String, org: String, email: String, name: String,
                     orgName: String, plan: String, conversations: [Script.Conversation],
                     codeTab: [Script.Conversation], mcp: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: userData, withIntermediateDirectories: true)
        try writeJSON(["lastKnownAccountUuid": account], to: userData.appendingPathComponent("config.json"))
        try writeJSON(["mcpServers": mcp.mapValues { command -> [String: Any] in
            let parts = command.split(separator: " ").map(String.init)
            return ["command": parts[0], "args": Array(parts.dropFirst())]
        }], to: userData.appendingPathComponent("claude_desktop_config.json"))

        // Electron leaves these behind whatever the app is doing; they give Storage something
        // honest to measure.
        for cache in ["Cache", "Code Cache", "GPUCache"] {
            try writeFiller(userData.appendingPathComponent(cache, isDirectory: true), megabytes: 3)
        }

        let orgDir = userData.appendingPathComponent(StoreLayout.sessionsDirName, isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
        try fm.createDirectory(at: orgDir, withIntermediateDirectories: true)
        // The org-level workspace record is where Claude keeps the organisation's name.
        try writeJSON(["oauthAccount": ["accountUuid": account, "emailAddress": email,
                                        "organizationUuid": org, "organizationName": orgName,
                                        "organizationType": plan]],
                      to: orgDir.appendingPathComponent(".claude.json"))

        for conversation in conversations {
            try writeCowork(conversation, orgDir: orgDir, email: email, name: name)
        }
        if account == Self.workAccount {
            let spaceID = "5d0c7a1e-3b2f-4c8d-9e6a-1f2b3c4d5e6f"
            try writeJSON(["spaces": [["id": spaceID, "name": "Q4 planning",
                                       "folders": [["path": paths.home.appendingPathComponent("Documents/Q4 planning").path]]]]],
                          to: orgDir.appendingPathComponent("spaces.json"))
            try FileManager.default.createDirectory(
                at: paths.home.appendingPathComponent("Documents/Q4 planning", isDirectory: true),
                withIntermediateDirectories: true)
            let memory = orgDir.appendingPathComponent("spaces/\(spaceID)/memory", isDirectory: true)
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            try Data("- Headcount plan is due to finance on the 15th.\n- Hiring order: reliability first.\n".utf8)
                .write(to: memory.appendingPathComponent("MEMORY.md"))
        }
        try writeCoworkPlugins(orgDir: orgDir, plugins: account == Self.workAccount
                                ? ["design", "engineering", "sales"] : ["design", "productivity"],
                               organisationPlugin: account == Self.workAccount ? "northwind-handbook" : nil)

        let codeTabDir = userData.appendingPathComponent("claude-code-sessions", isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
        try fm.createDirectory(at: codeTabDir, withIntermediateDirectories: true)
        for conversation in codeTab {
            try writeCodeTab(conversation, into: codeTabDir)
        }
        try writeJSON(["scheduledTasks": [] as [Any]],
                      to: codeTabDir.appendingPathComponent("scheduled-tasks.json"))
    }

    func writeCowork(_ conversation: Script.Conversation, orgDir: URL, email: String,
                     name: String) throws {
        let sessionId = "local_" + conversation.id
        let processName = conversation.processName
        let cwd = "/sessions/\(processName)"
        let started = now.addingTimeInterval(-conversation.age)
        let transcript = Transcriber(conversation: conversation, cwd: cwd, start: started)

        let workspace = orgDir.appendingPathComponent(sessionId, isDirectory: true)
        let projectDir = workspace.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcriptURL = projectDir.appendingPathComponent("\(conversation.cliId).jsonl")
        try transcript.data().write(to: transcriptURL)
        try touch(transcriptURL, at: transcript.end)

        if !conversation.outputs.isEmpty {
            let outputs = workspace.appendingPathComponent("outputs", isDirectory: true)
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            for (file, contents) in conversation.outputs {
                try Data(contents.utf8).write(to: outputs.appendingPathComponent(file))
            }
        }

        try writeJSON([
            "sessionId": sessionId,
            "cliSessionId": conversation.cliId,
            "processName": processName,
            "cwd": cwd,
            "title": conversation.title,
            "model": conversation.model,
            "createdAt": MetadataDocument.milliseconds(from: started),
            "lastActivityAt": MetadataDocument.milliseconds(from: transcript.end),
            "hostLoopMode": false,
            "isArchived": false,
            "emailAddress": email,
            "accountName": name,
            "initialMessage": conversation.turns.first?.user ?? "",
        ], to: orgDir.appendingPathComponent("\(sessionId).json"))
    }

    /// Cowork's plugins live beside the conversations, per organisation.
    func writeCoworkPlugins(orgDir: URL, plugins: [String], organisationPlugin: String?) throws {
        var installed: [String: Any] = [:]
        var enabled: [String: Bool] = [:]
        for plugin in plugins {
            let key = "\(plugin)@knowledge-work-plugins"
            let install = orgDir.appendingPathComponent(
                "cowork_plugins/cache/knowledge-work-plugins/\(plugin)/1.1.0", isDirectory: true)
            let skill = install.appendingPathComponent("skills/\(plugin)-review", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: \(plugin)-review\ndescription: Review work with the \(plugin) checklist\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
            installed[key] = [["scope": "user", "installPath": install.path, "version": "1.1.0"]]
            enabled[key] = true
        }
        try writeJSON(["version": 2, "plugins": installed],
                      to: orgDir.appendingPathComponent("cowork_plugins/installed_plugins.json"))
        try writeJSON(["enabledPlugins": enabled], to: orgDir.appendingPathComponent("cowork_settings.json"))

        if let organisationPlugin {
            let plugin = orgDir.appendingPathComponent("rpm/plugin_01SAMPLE", isDirectory: true)
            try writeJSON(["name": organisationPlugin, "version": "2.0.0"],
                          to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
            let skill = plugin.appendingPathComponent("skills/expense-policy", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: expense-policy\ndescription: Answer questions about expenses\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
        }
    }

    /// A Code tab session: metadata here, transcript in Claude Code's own projects folder.
    func writeCodeTab(_ conversation: Script.Conversation, into dir: URL) throws {
        let cwd = paths.home.appendingPathComponent(conversation.project ?? "Code").path
        let started = now.addingTimeInterval(-conversation.age)
        let transcript = Transcriber(conversation: conversation, cwd: cwd, start: started)
        if !conversation.transcriptGone {
            try writeClaudeCodeTranscript(transcript, cwd: cwd, id: conversation.cliId)
        }
        try writeJSON([
            "sessionId": "local_" + conversation.id,
            "cliSessionId": conversation.cliId,
            "title": conversation.title,
            "titleSource": "ai",
            "cwd": cwd,
            "originCwd": cwd,
            "branch": conversation.branch ?? "main",
            "sourceBranch": "main",
            "model": conversation.model,
            "createdAt": MetadataDocument.milliseconds(from: started),
            "lastActivityAt": MetadataDocument.milliseconds(from: transcript.end),
            "isArchived": false,
            "isStarred": conversation.starred,
            "completedTurns": conversation.turns.count,
        ], to: dir.appendingPathComponent("local_\(conversation.id).json"))
    }

    // MARK: - Parallex

    func makeParallexWork() throws {
        let slug = "claude-work"
        let instance = paths.applicationSupport
            .appendingPathComponent("Parallex/instances/\(slug)", isDirectory: true)
        let data = instance.appendingPathComponent("data", isDirectory: true)
        let wrapper = root.appendingPathComponent("Applications/Claude Work.app")
        try makeBundle(at: wrapper, identifier: "com.parallex.instance.\(slug)",
                       name: "Claude Work", executable: "parallex-launcher",
                       donor: iconDonors["Claude"])
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try writeJSON([
            "schemaVersion": 3,
            "name": "Claude Work",
            "slug": slug,
            "wrapperPath": wrapper.path,
            "bundleIdentifier": "com.parallex.instance.\(slug)",
            "targetApp": root.appendingPathComponent("Applications/Claude.app").path,
            "targetBundleID": Discovery.electronBundleIdentifier,
            "targetBinary": root.appendingPathComponent("Applications/Claude.app/Contents/MacOS/Claude").path,
            "mode": "data-dir",
            "arguments": ["--user-data-dir=\(data.path)"],
            "environment": ["CLAUDE_USER_DATA_DIR": data.path],
            "preset": "claude",
            "parallexVersion": "1.0.0",
            "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400 * 40)),
            "settings": ["badgeText": "W", "badgeColorHex": "#2F6BDE"],
        ], to: instance.appendingPathComponent("instance.json"))

        try makeDesktop(
            userData: data, account: Self.workAccount, org: Self.workOrg,
            email: "alex@northwind.co", name: "Alex Rivera",
            orgName: "Northwind", plan: "claude_team",
            conversations: Script.workCowork, codeTab: [],
            mcp: ["linear": "npx -y linear-mcp", "github": "npx -y @github/mcp-server",
                  "filesystem": "npx -y @modelcontextprotocol/server-filesystem ~/Work"])
    }

    // MARK: - Claude Science

    func makeScience() throws {
        let science = paths.home.appendingPathComponent(".claude-science", isDirectory: true)
        let org = science.appendingPathComponent("orgs/\(Self.personalOrg)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: org.appendingPathComponent("artifacts/proj_protein-fold", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("# Folding run summary\n\nThree candidate structures converged.\n".utf8)
            .write(to: org.appendingPathComponent("artifacts/proj_protein-fold/summary.md"))
        // Present so a test can prove it is never opened.
        try Data("sample-only-not-a-real-key".utf8)
            .write(to: science.appendingPathComponent("encryption.key"))
        try writeFiller(science.appendingPathComponent("conda", isDirectory: true), megabytes: 4)
    }

    // MARK: - Claude Code

    func makeClaudeCode() throws {
        let config = paths.claudeCodeConfigDir
        let fm = FileManager.default
        try fm.createDirectory(at: config, withIntermediateDirectories: true)

        for project in Script.projects {
            try fm.createDirectory(at: paths.home.appendingPathComponent(project, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        for conversation in Script.claudeCode {
            let cwd = paths.home.appendingPathComponent(conversation.project ?? "Code").path
            let started = now.addingTimeInterval(-conversation.age)
            try writeClaudeCodeTranscript(
                Transcriber(conversation: conversation, cwd: cwd, start: started),
                cwd: cwd, id: conversation.cliId)
        }

        // Sessions running now: one waiting on a permission, one working, one done. Their
        // pids are made up; a debug build reading the sample treats them as running.
        let sessions = config.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let live: [(Int, String, String, TimeInterval)] = Script.claudeCode.prefix(3).enumerated().map { offset, conversation in
            (90_001 + offset, conversation.cliId, ["waiting", "busy", "idle"][offset], [240, 780, 1_500][offset])
        }
        for (index, entry) in live.enumerated() {
            let conversation = Script.claudeCode[index]
            let millis = { (date: Date) in Int(date.timeIntervalSince1970 * 1000) }
            try writeJSON([
                "pid": entry.0, "sessionId": entry.1,
                "cwd": paths.home.appendingPathComponent(conversation.project ?? "Code").path,
                "kind": "interactive", "entrypoint": index == 1 ? "claude-desktop" : "cli",
                "status": entry.2, "startedAt": millis(now.addingTimeInterval(-3_600)),
                "statusUpdatedAt": millis(now.addingTimeInterval(-entry.3)),
            ], to: sessions.appendingPathComponent("\(entry.0).json"))
        }

        // Memory, including one for a project folder that has since been deleted.
        for (project, files) in Script.memory {
            let cwd = paths.home.appendingPathComponent(project).path
            let memory = config.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(PathEncoder.encode(cwd), isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
            try fm.createDirectory(at: memory, withIntermediateDirectories: true)
            for (name, body) in files {
                try Data(body.utf8).write(to: memory.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: paths.home.appendingPathComponent(Script.deletedProject))

        for (name, description) in Script.skills {
            let dir = config.appendingPathComponent("skills/\(name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: \(description)\n---\n\nSteps go here.\n".utf8)
                .write(to: dir.appendingPathComponent("SKILL.md"))
        }
        try Data("# Working with Alex\n\nPrefer small commits and plain explanations.\n".utf8)
            .write(to: config.appendingPathComponent("CLAUDE.md"))
        try writeJSON([
            "model": "claude-opus-5-5",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command",
                                                           "command": "afplay /System/Library/Sounds/Glass.aiff"]]]]],
            "env": ["SEARCH_API_KEY": "sk-sample-0000000000000000"],
        ], to: config.appendingPathComponent("settings.json"))
        var recorded: [String: Any] = [:]
        for project in Script.projects {
            recorded[paths.home.appendingPathComponent(project).path] = ["allowedTools": [] as [String]]
        }
        try Data("# journal-app\n\nSwiftUI app. Run tests with `swift test` before committing.\n".utf8)
            .write(to: paths.home.appendingPathComponent("Code/journal-app/CLAUDE.md"))
        try writeJSON([
            "projects": recorded,
            "oauthAccount": ["accountUuid": Self.personalAccount, "emailAddress": "alex@rivera.studio",
                             "organizationUuid": Self.personalOrg,
                             "organizationName": "alex@rivera.studio's Organization",
                             "organizationType": "claude_max"],
        ], to: paths.home.appendingPathComponent(".claude.json"))
    }

    func writeClaudeCodeTranscript(_ transcript: Transcriber, cwd: String, id: String) throws {
        let dir = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        try transcript.data().write(to: url)
        try touch(url, at: transcript.end)
    }

    // MARK: - Helpers

    func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }

    func writeFiller(_ dir: URL, megabytes: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunk = Data(repeating: 0x2E, count: 1_048_576)
        for index in 0..<megabytes {
            try chunk.write(to: dir.appendingPathComponent("data_\(index)"))
        }
    }

    func touch(_ url: URL, at date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

public enum FixtureError: Error, CustomStringConvertible {
    case notEmpty(String)

    public var description: String {
        switch self {
        case .notEmpty(let path): return "\(path) is not empty; a sample Mac is only built in an empty folder"
        }
    }
}

// MARK: - Transcripts

/// Turns a scripted conversation into Claude Code transcript records.
struct Transcriber {
    let conversation: Script.Conversation
    let cwd: String
    let start: Date

    var end: Date { start.addingTimeInterval(Double(conversation.turns.count) * 95 + 30) }

    func data() -> Data {
        var lines: [String] = []
        var parent: String?
        var clock = start
        var counter = 0
        func nextUUID() -> String {
            counter += 1
            return Self.uuid(seed: conversation.cliId, index: counter)
        }
        func emit(_ record: [String: Any]) {
            var record = record
            record["sessionId"] = conversation.cliId
            record["cwd"] = cwd
            record["timestamp"] = Self.stamp(clock)
            record["version"] = "2.1.281"
            let data = try! JSONSerialization.data(withJSONObject: record,
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
            lines.append(String(decoding: data, as: UTF8.self))
        }

        for turn in conversation.turns {
            let userId = nextUUID()
            emit(["type": "user", "uuid": userId, "parentUuid": parent ?? NSNull(),
                  "message": ["role": "user", "content": turn.user]])
            parent = userId
            clock.addTimeInterval(20)

            for tool in turn.tools {
                let useId = "toolu_" + nextUUID().replacingOccurrences(of: "-", with: "").prefix(20)
                let assistantId = nextUUID()
                emit(["type": "assistant", "uuid": assistantId, "parentUuid": parent!,
                      "message": ["role": "assistant", "model": conversation.model,
                                  "content": [["type": "tool_use", "id": String(useId),
                                               "name": tool.name, "input": tool.input]]]])
                parent = assistantId
                clock.addTimeInterval(4)
                let resultId = nextUUID()
                emit(["type": "user", "uuid": resultId, "parentUuid": parent!,
                      "message": ["role": "user",
                                  "content": [["type": "tool_result", "tool_use_id": String(useId),
                                               "content": tool.result]]]])
                parent = resultId
                clock.addTimeInterval(6)
            }

            let replyId = nextUUID()
            // Plausible token counts, derived from the text so they are the same every build.
            let context = 18_000 + lines.joined().utf8.count / 4
            emit(["type": "assistant", "uuid": replyId, "parentUuid": parent!,
                  "message": ["role": "assistant", "model": conversation.model,
                              "id": "msg_" + replyId.replacingOccurrences(of: "-", with: "").prefix(24),
                              "usage": ["input_tokens": 6 + turn.user.utf8.count / 4,
                                        "output_tokens": 40 + turn.assistant.utf8.count / 3,
                                        "cache_read_input_tokens": context,
                                        "cache_creation_input_tokens": 1_200 + turn.user.utf8.count,
                                        "cache_creation": ["ephemeral_5m_input_tokens": 0,
                                                           "ephemeral_1h_input_tokens": 1_200 + turn.user.utf8.count]],
                              "content": [["type": "text", "text": turn.assistant]]]])
            parent = replyId
            clock.addTimeInterval(65)
        }
        emit(["type": "ai-title", "aiTitle": conversation.title])
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Deterministic, well-formed UUIDs, so a sample Mac rebuilt tomorrow has the same ids.
    static func uuid(seed: String, index: Int) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in "\(seed)#\(index)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        var second = hash
        second = (second ^ 0x9E3779B97F4A7C15) &* 0xBF58476D1CE4E5B9
        let hex = String(format: "%016llx%016llx", hash, second)
        let c = Array(hex)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-4\(String(c[13..<16]))-a\(String(c[17..<20]))-\(String(c[20..<32]))"
    }
}
