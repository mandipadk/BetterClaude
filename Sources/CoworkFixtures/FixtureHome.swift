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
                  "calendar": "/usr/local/bin/calendar-mcp",
                  // Better Claude's own history server, as its switch adds it.
                  "better-claude": "/Applications/BetterClaude.app/Contents/MacOS/bc-recall --account \(Self.personalAccount)"])
        try makeParallexWork()
        try makeScience()
        try makeClaudeCode()
        try makeKept()
        try makeCodex()
    }

    /// A Codex home with one session, the way the Codex CLI leaves it: a header, injected
    /// context that isn't the person's, a prompt, a tool call and a reply. `auth.json` is
    /// there to show it's never read.
    func makeCodex() throws {
        let home = paths.home.appendingPathComponent(".codex", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/09/20", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data(#"{"OPENAI_API_KEY":"sk-sample-not-real"}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        let id = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let start = now.addingTimeInterval(-4 * 86_400)
        let cwd = paths.home.appendingPathComponent("Code/billing-service").path
        func stamp(_ offset: TimeInterval) -> String { Transcriber.stamp(start.addingTimeInterval(offset)) }
        let records: [[String: Any]] = [
            ["timestamp": stamp(0), "type": "session_meta",
             "payload": ["id": id, "timestamp": stamp(0), "cwd": cwd, "originator": "codex_cli_rs",
                         "cli_version": "0.51.0", "git": ["branch": "main"]]],
            ["timestamp": stamp(1), "type": "turn_context", "payload": ["cwd": cwd, "model": "gpt-5-codex"]],
            ["timestamp": stamp(2), "type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "<environment_context>\n  <cwd>\(cwd)</cwd>\n</environment_context>"]]]],
            ["timestamp": stamp(3), "type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "Why do refunds post twice when the webhook retries?"]]]],
            ["timestamp": stamp(20), "type": "response_item",
             "payload": ["type": "function_call", "name": "shell", "arguments": #"{"command":["rg","refund"]}"#, "call_id": "c1"]],
            ["timestamp": stamp(60), "type": "response_item",
             "payload": ["type": "message", "role": "assistant",
                         "content": [["type": "output_text", "text": "The refund handler isn't idempotent: a retried delivery creates a second refund. Keying refunds by event id fixes it."]]]],
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        let file = day.appendingPathComponent("rollout-2026-09-20T10-00-00-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try touch(file, at: start.addingTimeInterval(60))
        try Data((#"{"id":"\#(id)","thread_name":"Refunds post twice on webhook retry","updated_at":"\#(stamp(60))"}"# + "\n").utf8)
            .write(to: home.appendingPathComponent("session_index.jsonl"))
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

        let spaceID = "5d0c7a1e-3b2f-4c8d-9e6a-1f2b3c4d5e6f"
        for conversation in conversations {
            let inProject = account == Self.workAccount
                && (conversation.title.hasPrefix("Q4 hiring") || conversation.title.hasPrefix("Customer interview"))
            try writeCowork(conversation, orgDir: orgDir, email: email, name: name,
                            spaceID: inProject ? spaceID : nil)
        }
        try writeUsageHistory(to: userData, org: org, weeklyNow: account == Self.workAccount ? 76 : 46)
        if account == Self.workAccount {
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
                     name: String, spaceID: String? = nil) throws {
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

        var metadata: [String: Any] = [
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
        ]
        if let spaceID { metadata["spaceId"] = spaceID }
        try writeJSON(metadata, to: orgDir.appendingPathComponent("\(sessionId).json"))
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

        try writeFileHistory()
        try writeLongSession()
        try writeLeakedKeys()
        try writeCorrections()
        try writeSubagents()
        try writeUnattended()
        try writePromptHistory()

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
            "cachedUsageUtilization": [
                "accountUuid": Self.personalAccount,
                "fetchedAtMs": Int(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000),
                "utilization": [
                    "five_hour": ["utilization": 34, "resets_at": Transcriber.stamp(now.addingTimeInterval(2 * 3_600 + 1_200))],
                    "seven_day": ["utilization": 46, "resets_at": Transcriber.stamp(weekStart.addingTimeInterval(7 * 86_400))],
                    "seven_day_opus": NSNull(),
                ] as [String: Any],
            ] as [String: Any],
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

    /// The week began on the hour five days ago; the week before ended high, so its reset
    /// shows as a drop.
    public var weekStart: Date {
        let hour = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(-5 * 86_400)
    }

    /// `plan-usage-history.json`, as Claude Desktop samples it: a reading every half hour
    /// over nine days, the week's figure climbing steadily and the five-hour one rising and
    /// falling with the day.
    func writeUsageHistory(to userData: URL, org: String, weeklyNow: Double) throws {
        var samples: [[String: Any]] = []
        var time = now.addingTimeInterval(-9 * 86_400)
        while time <= now.addingTimeInterval(-60) {
            let inWeek = time >= weekStart
            let span = inWeek ? now.timeIntervalSince(weekStart) : weekStart.timeIntervalSince(now.addingTimeInterval(-9 * 86_400))
            let progress = inWeek ? time.timeIntervalSince(weekStart) / span
                                  : 0.55 + 0.3 * time.timeIntervalSince(now.addingTimeInterval(-9 * 86_400)) / span
            let weekly = inWeek ? weeklyNow * progress : 60 + 25 * progress
            let hourOfDay = Calendar(identifier: .gregorian).component(.hour, from: time)
            let fiveHour = (9...22).contains(hourOfDay) ? Double((hourOfDay * 7) % 38 + 6) : 0
            samples.append(["t": Int(time.timeIntervalSince1970 * 1000), "org": org,
                            "u": ["fh": Int(fiveHour), "sd": Int(weekly)]])
            time.addTimeInterval(1_800)
        }
        try writeJSON(["samples": samples], to: userData.appendingPathComponent("plan-usage-history.json"))
    }

    /// The webhook conversation's sub-agents: one that searched, one that wrote tests and
    /// spawned a searcher of its own, and an older one that died before it answered.
    func writeSubagents() throws {
        guard let conversation = Script.claudeCode.first(where: { $0.title.hasPrefix("Retry failed webhook") }) else { return }
        let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
        let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deliver = project.appendingPathComponent("src/webhooks/deliver.ts").path
        struct Agent { let id, type, model, description, prompt: String; let result: String?; let parent: String?; let depth: Int
                       let tools: [(String, [String: Any])]; let start: Double }
        let agents = [
            Agent(id: "a1f0search", type: "Explore", model: "claude-sonnet-5", description: "Find every place deliveries are retried",
                  prompt: "Find every place webhook deliveries are retried or re-queued, and list them with file and line.",
                  result: "Deliveries are retried in one place, `deliver()` in src/webhooks/deliver.ts. The queue worker calls it once per event and never re-queues. I also updated deliver.ts to log each retry.",
                  parent: nil, depth: 1, tools: [("Grep", ["pattern": "deliver\\("]), ("Read", ["file_path": deliver])], start: 40),
            Agent(id: "b2e1tests", type: "general-purpose", model: "claude-opus-5-5", description: "Write tests for the backoff curve",
                  prompt: "Write tests for nextDelay in src/webhooks/backoff.ts: the curve, the jitter bounds, and the cap.",
                  result: "Added 6 tests in backoff.test.ts covering the doubling curve, jitter staying within half the base, and the ten minute cap. All pass.",
                  parent: nil, depth: 1, tools: [("Read", ["file_path": deliver]), ("Write", ["file_path": project.appendingPathComponent("src/webhooks/backoff.test.ts").path]),
                                                 ("Bash", ["command": "pnpm test backoff"])], start: 90),
            Agent(id: "c3d2helper", type: "Explore", model: "claude-sonnet-5", description: "Find the test helpers for timers",
                  prompt: "Find how existing tests fake timers.", result: "They use vi.useFakeTimers() from test/setup.ts.",
                  parent: "b2e1tests", depth: 2, tools: [("Grep", ["pattern": "useFakeTimers"])], start: 100),
        ]
        func line(_ record: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        for agent in agents {
            var lines: [String] = []
            var clock = now.addingTimeInterval(-conversation.age + agent.start)
            lines.append(try line(["type": "user", "isSidechain": true, "agentId": agent.id, "timestamp": Transcriber.stamp(clock),
                                   "message": ["role": "user", "content": agent.prompt]]))
            var context = 9_000
            for (step, tool) in agent.tools.enumerated() {
                clock.addTimeInterval(12)
                context += 2_500
                lines.append(try line(["type": "assistant", "isSidechain": true, "agentId": agent.id, "timestamp": Transcriber.stamp(clock),
                                       "message": ["role": "assistant", "model": agent.model, "id": "msg_\(agent.id)_\(step)",
                                                   "usage": ["input_tokens": 3, "output_tokens": 120, "cache_read_input_tokens": context,
                                                             "cache_creation_input_tokens": 900],
                                                   "content": [["type": "tool_use", "id": "toolu_\(agent.id)_\(step)", "name": tool.0, "input": tool.1]]]]))
                lines.append(try line(["type": "user", "isSidechain": true, "agentId": agent.id, "timestamp": Transcriber.stamp(clock),
                                       "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_\(agent.id)_\(step)", "content": "ok",
                                                                                 // The test writer's test run failed, whatever it reported.
                                                                                 "is_error": agent.id == "b2e1tests" && tool.0 == "Bash"]]]]))
            }
            if let result = agent.result {
                clock.addTimeInterval(10)
                lines.append(try line(["type": "assistant", "isSidechain": true, "agentId": agent.id, "timestamp": Transcriber.stamp(clock),
                                       "message": ["role": "assistant", "model": agent.model, "id": "msg_\(agent.id)_final",
                                                   "usage": ["input_tokens": 3, "output_tokens": 220, "cache_read_input_tokens": context + 1_500,
                                                             "cache_creation_input_tokens": 600],
                                                   "content": [["type": "text", "text": result]]]]))
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("agent-\(agent.id).jsonl"))
            var meta: [String: Any] = ["agentType": agent.type, "description": agent.description,
                                       "toolUseId": "toolu_spawn_\(agent.id)", "spawnDepth": agent.depth]
            if let parent = agent.parent { meta["parentAgentId"] = parent }
            // The helper was asked to run on Opus, and didn't.
            if agent.id == "c3d2helper" { meta["model"] = "opus" }
            try Data(try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])).write(to: folder.appendingPathComponent("agent-\(agent.id).meta.json"))
        }
        // An older sub-agent, from before Claude Code wrote a meta file, that stopped mid-task.
        let old = [try line(["type": "user", "isSidechain": true, "timestamp": Transcriber.stamp(now.addingTimeInterval(-conversation.age + 150)),
                             "message": ["role": "user", "content": "Check whether the dead-letter queue has an alert on it."]]),
                   try line(["type": "assistant", "isSidechain": true, "timestamp": Transcriber.stamp(now.addingTimeInterval(-conversation.age + 160)),
                             "message": ["role": "assistant", "model": "claude-sonnet-5", "id": "msg_d4old_0",
                                         "usage": ["input_tokens": 3, "output_tokens": 80, "cache_read_input_tokens": 8_000, "cache_creation_input_tokens": 500],
                                         "content": [["type": "tool_use", "id": "toolu_d4old_0", "name": "Grep", "input": ["pattern": "deadLetter"]]]]])]
        try Data((old.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("agent-d4e3older.jsonl"))
    }

    /// Background jobs as Claude Code keeps them in `jobs/<id>/`: one that finished, one that
    /// failed, and one whose record still says it's working though nothing has moved in hours.
    /// And a conversation that kept itself going with scheduled wake-ups.
    func writeUnattended() throws {
        let jobs = paths.claudeCodeConfigDir.appendingPathComponent("jobs", isDirectory: true)
        let billing = paths.home.appendingPathComponent("Code/billing-service").path
        let journal = paths.home.appendingPathComponent("Code/journal-app").path
        let entries: [(String, String, String, String?, TimeInterval, [String])] = [
            ("7f3a91c2", "Nightly dependency audit", "done",
             "No vulnerable versions. Two minor updates available: vitest 3.4 and zod 4.2.", 40 * 60, ["Reading the lockfile", "Checking advisories"]),
            ("2b8e04d1", "Refresh the fixtures", "failed", nil, 3 * 3_600, ["Regenerating fixtures", "The seed script exited with an error"]),
            ("c91d5e77", "Translate settings strings", "working", nil, 2 * 3_600, ["Translating 42 strings into German"]),
        ]
        for (id, name, state, result, age, timeline) in entries {
            let folder = jobs.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var record: [String: Any] = [
                "name": name, "state": state, "backend": "daemon", "tempo": state == "working" ? "working" : "idle",
                "cwd": id == "c91d5e77" ? journal : billing, "sessionId": UUID().uuidString.lowercased(),
                "createdAt": Transcriber.stamp(now.addingTimeInterval(-age - 600)), "updatedAt": Transcriber.stamp(now.addingTimeInterval(-age)),
                "tokens": 48_000, "providerEnv": ["NOT_READ": "x"], "output": [:] as [String: Any],
            ]
            if let result { record["output"] = ["result": result] }
            try writeJSON(record, to: folder.appendingPathComponent("state.json"))
            let lines = try timeline.enumerated().map { offset, text in
                String(decoding: try JSONSerialization.data(withJSONObject: [
                    "at": Transcriber.stamp(now.addingTimeInterval(-age - Double(timeline.count - offset) * 60)), "state": "working", "text": text,
                ], options: [.sortedKeys]), as: UTF8.self)
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("timeline.jsonl"))
        }

        guard let conversation = Script.claudeCode.first(where: { $0.title.hasPrefix("Add a health check") }) else { return }
        let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
        let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        for step in 0..<6 {
            let record: [String: Any] = [
                "type": "assistant", "isSidechain": true,
                "timestamp": Transcriber.stamp(now.addingTimeInterval(-26 * 3_600 + Double(step) * 1_800)),
                "message": ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_wake\(step)", "name": "ScheduleWakeup",
                                                              "input": ["delaySeconds": 1_800, "reason": "check the deploy"]]]],
            ]
            try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8))
        }
        try handle.close()
    }

    /// The same two corrections in two billing-service conversations: what a project's
    /// CLAUDE.md should have said.
    func writeCorrections() throws {
        let exchanges: [(String, [(String, String)])] = [
            ("Retry failed webhook deliveries with backoff", [
                ("I'll add the retry library with npm install.", "No, use pnpm here, not npm."),
                ("Logged the full request body on each failed attempt.", "Don't log request bodies, they can hold card details."),
                ("Should the total wait be capped at five or ten minutes?", "Let's go with a ten minute cap on the total wait."),
            ]),
            ("Add a health check endpoint", [
                ("Installing the health check package with npm.", "no, this repo uses pnpm not npm"),
                ("Added the request body to the error log for debugging.", "Please don't log request bodies. They can contain card details."),
            ]),
        ]
        for (title, pairs) in exchanges {
            guard let conversation = Script.claudeCode.first(where: { $0.title == title }) else { continue }
            let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
            let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
                .appendingPathComponent("\(conversation.cliId).jsonl")
            var added: [String] = []
            for (index, pair) in pairs.enumerated() {
                let time = Transcriber.stamp(now.addingTimeInterval(-conversation.age + 300 + Double(index) * 60))
                let ask = Transcriber.uuid(seed: conversation.cliId + "correction", index: index * 2)
                let answer = Transcriber.uuid(seed: conversation.cliId + "correction", index: index * 2 + 1)
                for record: [String: Any] in [
                    ["type": "assistant", "uuid": answer, "sessionId": conversation.cliId, "timestamp": time,
                     "message": ["role": "assistant", "content": [["type": "text", "text": pair.0]]]],
                    ["type": "user", "uuid": ask, "parentUuid": answer, "sessionId": conversation.cliId, "timestamp": time,
                     "message": ["role": "user", "content": pair.1]],
                ] {
                    added.append(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
                }
            }
            // Before the conversation's last question, so its last exchange stays its own.
            var lines = try String(contentsOf: transcript, encoding: .utf8).components(separatedBy: "\n")
            let lastAsk = lines.lastIndex { $0.contains("\"type\":\"user\"") && !$0.contains("tool_result")
                && !$0.contains("isSidechain") && !$0.contains("correction") }
            lines.insert(contentsOf: added, at: lastAsk ?? max(0, lines.count - 1))
            try Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        }
    }

    /// Invented keys that ended up in a conversation: one pasted in, one printed by a command.
    /// Built at run time, so nothing key-shaped sits in the source.
    public static var sampleKeys: (anthropic: String, aws: String) {
        ("sk-" + "ant-" + "api03-" + String(repeating: "Zq7vN2sample", count: 8) + "AA",
         "AK" + "IA" + "SAMPLE7Q3XN4BZ2P")
    }

    func writeLeakedKeys() throws {
        guard let conversation = Script.claudeCode.first(where: { $0.title.hasPrefix("Add a health check") }) else { return }
        let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
        let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        let time = Transcriber.stamp(now.addingTimeInterval(-conversation.age + 200))
        let keys = Self.sampleKeys
        let records: [[String: Any]] = [
            ["type": "user", "isSidechain": true, "timestamp": time,
             "message": ["role": "user", "content": "The staging check needs this key: \(keys.anthropic)"]],
            ["type": "user", "isSidechain": true, "timestamp": time, "toolUseResult": ["stdout": "…"],
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_env",
                                                      "content": "AWS_ACCESS_KEY_ID=\(keys.aws)\nAWS_REGION=eu-west-1"]]]],
        ]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        for record in records {
            try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8))
        }
        try handle.close()
    }

    /// The date picker migration as a long working session: a sub-agent's replies reading
    /// more and more of the conversation, a compaction, then more work — what a heavy session
    /// looks like reply by reply.
    func writeLongSession() throws {
        guard let conversation = Script.claudeCode.first(where: { $0.title.hasPrefix("Migrate the date picker") }) else { return }
        let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
        let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        let start = now.addingTimeInterval(-conversation.age - 4.5 * 3_600)
        var lines: [Data] = []
        var context = 24_000
        for step in 0..<72 {
            // A long break at step 30: the cache expired, and the next reply wrote it all again.
            let time = start.addingTimeInterval(Double(step) * 140 + (step >= 30 ? 5_400 : 0))
            if step == 20 {
                // Two instructions: the summary keeps the second and drops the first.
                lines.append(try JSONSerialization.data(withJSONObject: [
                    "type": "user", "isSidechain": true, "timestamp": Transcriber.stamp(time),
                    "message": ["role": "user", "content": "Don't change the date format in exported CSVs, finance parses them. Keep the old picker behind a flag until the locale test passes."],
                ] as [String: Any], options: [.sortedKeys]))
            }
            if step == 44 {
                lines.append(try JSONSerialization.data(withJSONObject: [
                    "type": "user", "isSidechain": true, "isCompactSummary": true, "timestamp": Transcriber.stamp(time),
                    "message": ["role": "user", "content": "Summary of the migration so far: DatePicker call sites moved to the new API in 14 of 22 files. Decided to keep the old picker behind a flag until the locale fallback has a test."],
                ] as [String: Any], options: [.sortedKeys]))
                context = 31_000
            }
            // Deterministic growth with a little texture.
            context += 3_100 + (step * 37) % 1_900
            let id = "msg_long\(step)"
            lines.append(try JSONSerialization.data(withJSONObject: [
                "type": "assistant", "isSidechain": true, "timestamp": Transcriber.stamp(time),
                // Partway through, replies came from another model with nothing asking for it.
                "message": ["role": "assistant", "model": step >= 50 ? "claude-opus-4-8" : conversation.model, "id": id,
                            "usage": ["input_tokens": 4, "output_tokens": 180 + (step * 53) % 900,
                                      "cache_read_input_tokens": step == 30 ? 0 : context,
                                      "cache_creation_input_tokens": step == 30 ? context : 2_000 + (step * 71) % 3_000],
                            "content": [["type": "tool_use", "id": "toolu_long\(step)", "name": step % 3 == 0 ? "Edit" : "Read",
                                         "input": ["file_path": project.appendingPathComponent("src/DatePicker.tsx").path]]]],
            ] as [String: Any], options: [.sortedKeys]))
        }
        // Then you switched back, with /model, before the conversation's own turns.
        lines.append(try JSONSerialization.data(withJSONObject: [
            "type": "user", "isSidechain": true, "timestamp": Transcriber.stamp(now.addingTimeInterval(-conversation.age - 60)),
            "message": ["role": "user", "content": "<command-name>/model</command-name>\n<command-args>sonnet</command-args>"],
        ] as [String: Any], options: [.sortedKeys]))
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        for line in lines { try handle.write(contentsOf: line + Data("\n".utf8)) }
        try handle.close()
    }

    /// The webhook conversation's files, as Claude Code leaves them: `deliver.ts` as it is
    /// now with the version saved before Claude's edit, and `backoff.ts`, which Claude
    /// created — recorded as a version that didn't exist.
    func writeFileHistory() throws {
        guard let conversation = Script.claudeCode.first(where: { $0.title.hasPrefix("Retry failed webhook") }) else { return }
        let project = paths.home.appendingPathComponent(conversation.project ?? "Code")
        let folder = project.appendingPathComponent("src/webhooks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deliver = folder.appendingPathComponent("deliver.ts")
        let backoff = folder.appendingPathComponent("backoff.ts")
        try Data(Self.deliverNow.utf8).write(to: deliver)
        try Data(Self.backoffNow.utf8).write(to: backoff)
        // Last written by the conversation, as they would be.
        for file in [deliver, backoff] {
            try touch(file, at: now.addingTimeInterval(-conversation.age + 30))
        }

        let history = paths.claudeCodeConfigDir.appendingPathComponent("file-history/\(conversation.cliId)", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data(Self.deliverBefore.utf8).write(to: history.appendingPathComponent("3f1c9a2b7d4e8f60@v1"))

        let transcript = paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoder.encode(project.path), isDirectory: true)
            .appendingPathComponent("\(conversation.cliId).jsonl")
        let saved = Transcriber.stamp(now.addingTimeInterval(-conversation.age + 25))
        let record: [String: Any] = [
            "type": "file-history-snapshot", "messageId": Transcriber.uuid(seed: conversation.cliId, index: 1),
            "isSnapshotUpdate": false,
            "snapshot": ["messageId": Transcriber.uuid(seed: conversation.cliId, index: 1), "timestamp": saved,
                         "trackedFileBackups": [
                            deliver.path: ["backupFileName": "3f1c9a2b7d4e8f60@v1", "version": 1, "backupTime": saved],
                            backoff.path: ["backupFileName": NSNull(), "version": 1, "backupTime": saved],
                         ]],
        ]
        let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        // One MCP server that wouldn't start, for the doctor to find.
        let health = try JSONSerialization.data(withJSONObject: [
            "type": "attachment", "timestamp": saved,
            "attachment": ["type": "deferred_tools_delta", "addedNames": [String](),
                           "failedMcpServers": [["name": "linear", "errorCode": "ECONNREFUSED", "error": "connect failed"]],
                           "needsAuthMcpServers": ["github"]],
        ] as [String: Any], options: [.sortedKeys])
        // The pull request the work went into.
        let pull = try JSONSerialization.data(withJSONObject: [
            "type": "pr-link", "sessionId": conversation.cliId, "timestamp": saved, "prNumber": 318,
            "prRepository": "northwind/billing-service", "prUrl": "https://github.com/northwind/billing-service/pull/318",
        ] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes])
        // A second version of deliver.ts, saved as the second prompt's turn began.
        try Data(Self.deliverMiddle.utf8).write(to: history.appendingPathComponent("3f1c9a2b7d4e8f60@v2"))
        let prompts = try String(contentsOf: transcript, encoding: .utf8).components(separatedBy: "\n").compactMap { line -> String? in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "user", let message = record["message"] as? [String: Any],
                  message["content"] is String else { return nil }
            return record["uuid"] as? String
        }
        let middle = try JSONSerialization.data(withJSONObject: [
            "type": "file-history-delta", "messageId": "delta-2", "snapshotMessageId": prompts.dropFirst().first ?? "",
            "trackingPath": deliver.path, "timestamp": Transcriber.stamp(now.addingTimeInterval(-conversation.age + 120)),
            "backup": ["backupFileName": "3f1c9a2b7d4e8f60@v2", "version": 2,
                       "backupTime": Transcriber.stamp(now.addingTimeInterval(-conversation.age + 120))],
        ] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes])
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data("\n".utf8) + middle + Data("\n".utf8) + health + Data("\n".utf8)
                         + pull + Data("\n".utf8))
        try handle.close()
        try touch(transcript, at: now.addingTimeInterval(-conversation.age + Double(conversation.turns.count) * 95 + 30))
    }

    /// `history.jsonl`: what was typed, including a few prompts typed again and again.
    func writePromptHistory() throws {
        let billing = paths.home.appendingPathComponent("Code/billing-service").path
        let journal = paths.home.appendingPathComponent("Code/journal-app").path
        let typed: [(String, String, TimeInterval)] = [
            ("Run the tests and fix anything that fails, then summarise what changed", billing, 6 * 86_400),
            ("Run the tests and fix anything that fails, then summarize what changed", journal, 5 * 86_400),
            ("run the tests and fix anything that fails then summarise what changed", billing, 3 * 86_400),
            ("Run the tests and fix anything that fails, then summarise what changed", billing, 1 * 86_400),
            ("Write release notes for everything merged since the last tag, for people rather than developers", journal, 9 * 86_400),
            ("Write release notes for everything merged since the last tag, for people rather than developers", journal, 2 * 86_400),
            ("Write release notes for everything merged since the last tag, for people rather than developers", billing, 4 * 3_600),
            ("Review this diff for anything that could break in production", billing, 8 * 86_400),
            ("Review this diff for anything that could break in production", billing, 2 * 86_400),
            ("yes", billing, 3_600), ("continue", billing, 3_500),
        ]
        let lines = try typed.map { text, project, age in
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "display": text, "project": project, "pastedContents": [String: String](),
                "timestamp": Int(now.addingTimeInterval(-age).timeIntervalSince1970 * 1000),
                "sessionId": UUID().uuidString.lowercased(),
            ], options: [.sortedKeys]), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: paths.claudeCodeConfigDir.appendingPathComponent("history.jsonl"))
    }

    public static let deliverBefore = """
        export async function deliver(event: WebhookEvent) {
          const response = await fetch(event.url, { method: "POST", body: JSON.stringify(event.payload) })
          if (!response.ok) {
            log.warn("webhook delivery failed", { id: event.id, status: response.status })
          }
        }

        """

    /// Halfway: retries without backoff, before the cap was asked for.
    public static let deliverMiddle = """
        export async function deliver(event: WebhookEvent, attempt = 0) {
          const response = await fetch(event.url, { method: "POST", body: JSON.stringify(event.payload) })
          if (response.ok) return
          log.warn("webhook delivery failed", { id: event.id, status: response.status, attempt })
          return deliver(event, attempt + 1)
        }

        """

    public static let deliverNow = """
        import { nextDelay } from "./backoff"

        export async function deliver(event: WebhookEvent, attempt = 0) {
          const response = await fetch(event.url, { method: "POST", body: JSON.stringify(event.payload) })
          if (response.ok) return
          if (attempt >= 4) return deadLetter.push(event)
          await sleep(nextDelay(attempt))
          return deliver(event, attempt + 1)
        }

        """

    public static let backoffNow = """
        export function nextDelay(attempt: number): number {
          const base = 2 ** attempt * 1_000
          return base / 2 + Math.random() * (base / 2)
        }

        """

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
                // Claude Code names files by absolute path.
                var input = tool.input
                if let path = input["file_path"] as? String, !path.hasPrefix("/") {
                    input["file_path"] = (cwd as NSString).appendingPathComponent(path)
                }
                let useId = "toolu_" + nextUUID().replacingOccurrences(of: "-", with: "").prefix(20)
                let assistantId = nextUUID()
                emit(["type": "assistant", "uuid": assistantId, "parentUuid": parent!,
                      "message": ["role": "assistant", "model": conversation.model,
                                  "content": [["type": "tool_use", "id": String(useId),
                                               "name": tool.name, "input": input]]]])
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
