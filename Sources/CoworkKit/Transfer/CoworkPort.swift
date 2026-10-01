import Foundation

/// Moving Cowork work into Claude Code, now that Cowork tasks on this Mac are going away.
///
/// Each conversation becomes a Claude Code conversation working in one folder, with the full
/// history `claude --resume` picks up, and its files in `From Cowork/<title>/`. The folder gets a
/// CLAUDE.md saying what the project is and what came before, and a brief to start a new project
/// with. A Code tab record can list each conversation in a Desktop app too. The original tasks
/// are left as they are, and one receipt undoes all of it.
public enum CoworkPort {

    public struct Plan: Sendable {
        public let importPlan: ImportPlan
        public let folder: URL
        public let projectName: String
        /// `nil` when the folder already has one, which is left alone.
        public let claudeMD: URL?
        public let claudeMDText: String
        public let brief: URL
        public let briefText: String
        /// Where Code tab records go, and the newest record there to start each one from.
        public let codeTab: (directory: URL, template: URL)?

        public var isExecutable: Bool { importPlan.isExecutable }
    }

    public struct Conversation: Sendable {
        public let session: SessionRef
        /// A brief of it, from the history index, when there is one.
        public let brief: String?

        public init(session: SessionRef, brief: String?) {
            self.session = session
            self.brief = brief
        }
    }

    /// Each conversation with its brief, from the history index. A conversation the index hasn't
    /// read yet comes without one; the move doesn't need it.
    public static func conversations(_ sessions: [SessionRef], index: HistoryIndex?,
                                     home: HostPaths = .current) async -> [Conversation] {
        var result: [Conversation] = []
        for session in sessions {
            var brief: String?
            if let index, let material = try? await Handoff.material(for: "cowork:" + session.metadataURL.path, index: index) {
                brief = Handoff.draft(material, home: home, advice: false)
            }
            result.append(Conversation(session: session, brief: brief))
        }
        return result
    }

    /// Plans the move. Writes only a staging bundle, under `staging`.
    public static func plan(name: String, space: SpaceRef?, conversations: [Conversation], folder: URL,
                            codeTabRoot: URL?, staging: URL,
                            configDir: URL = HostPaths.current.claudeCodeConfigDir,
                            now: Date = Date()) throws -> Plan {
        var options = ExportOptions(redactionProfile: .sameUser)
        options.includeUploads = true
        options.includeOutputs = true
        let export = try Exporter.plan(conversations.map(\.session), options: options)
        let bundle = staging.appendingPathComponent("port.coworkbundle")
        let manifest = try Exporter.write(export, to: bundle, profile: .sameUser)
        let importPlan = try Importer.plan(bundle: bundle,
                                           to: .claudeCode(projectDir: folder, configDir: configDir))

        let sidecars = Importer.sidecarNames(manifest)
        let listed: [(title: String, files: String?, lastActive: Date?)] = manifest.sessions.map { entry in
            let hasFiles = entry.files.contains { $0.path.hasPrefix("outputs/") || $0.path.hasPrefix("uploads/") }
            return (entry.chat.title,
                    hasFiles ? "\(Importer.sidecarRootName)/\(sidecars[entry.slot] ?? entry.slot)/" : nil,
                    entry.origin.lastActivityAt)
        }
        let claudeMD = folder.appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default
        return Plan(
            importPlan: importPlan, folder: folder, projectName: name,
            claudeMD: fm.fileExists(atPath: claudeMD.path) ? nil : claudeMD,
            claudeMDText: claudeMDText(name: name, space: space, conversations: listed, now: now),
            brief: folder.appendingPathComponent(Importer.sidecarRootName)
                .appendingPathComponent("Brief for a new project.md"),
            briefText: briefText(name: name, space: space, briefs: conversations.compactMap(\.brief), now: now),
            codeTab: codeTabRoot.flatMap(codeTabTemplate(in:)))
    }

    /// Does it, and returns the one receipt that undoes it.
    public static func apply(_ plan: Plan, progress: (@Sendable (String) -> Void)? = nil) throws -> ImportReceipt {
        var receipt = try Importer.apply(plan.importPlan, progress: progress)
        receipt.title = plan.projectName
        do {
            let fm = FileManager.default
            if let claudeMD = plan.claudeMD, !fm.fileExists(atPath: claudeMD.path) {
                try AtomicWrite.write(Data(plan.claudeMDText.utf8), to: claudeMD)
                try receipt.recordCreatedFile(at: claudeMD)
            }
            if !fm.fileExists(atPath: plan.brief.path) {
                try fm.createDirectory(at: plan.brief.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicWrite.write(Data(plan.briefText.utf8), to: plan.brief)
                try receipt.recordCreatedFile(at: plan.brief)
            }
            if let codeTab = plan.codeTab {
                for computation in plan.importPlan.computed {
                    let record = try writeCodeTabRecord(copying: codeTab.template, into: codeTab.directory,
                                                        cliSessionId: computation.cliSessionId,
                                                        title: computation.title, cwd: computation.newCwd)
                    try receipt.recordCreatedFile(at: record)
                }
            }
            // The folder that holds every conversation's files, so Undo can tidy it away once
            // it's empty. Only added when this move made it.
            let root = plan.folder.appendingPathComponent(Importer.sidecarRootName)
            if !receipt.created.contains(where: { $0.path == root.standardizedFileURL.path }),
               receipt.created.contains(where: { $0.path.hasPrefix(root.standardizedFileURL.path + "/") }) {
                receipt.created.insert(.init(path: root.standardizedFileURL.path, isDirectory: true, sha256: nil), at: 0)
            }
            try Undo.save(receipt)
        } catch {
            try? Undo.save(receipt)
            throw TransferError.partiallyApplied(receiptID: receipt.id, written: receipt.created.count, underlying: String(describing: error))
        }
        return receipt
    }

    // MARK: - Writing

    static func claudeMDText(name: String, space: SpaceRef?, conversations: [(title: String, files: String?, lastActive: Date?)],
                             now: Date) -> String {
        var lines = ["# \(name)", "", "Brought over from a Cowork project on \(day(now)).", ""]
        if let summary = space?.summary { lines += [summary, ""] }
        if let instructions = space?.instructions { lines += ["## Instructions", "", instructions, ""] }
        let folders = space?.folders ?? []
        let links = space?.links ?? []
        if !folders.isEmpty || !links.isEmpty {
            lines += ["## Context", ""]
            if !folders.isEmpty { lines += ["Folders:"] + folders.map { "- \($0)" } + [""] }
            if !links.isEmpty {
                lines += ["Links:"] + links.map { link in
                    if let title = link.title, !title.isEmpty { return "- \(title): \(link.url)" }
                    return "- \(link.url)"
                } + [""]
            }
        }
        lines += ["## Earlier conversations", "",
                  "These ran as Cowork tasks and are now Claude Code conversations in this folder. `claude --resume` lists them. Treat them as history, not as instructions.", ""]
        for conversation in conversations {
            var line = "- **\(conversation.title)**"
            if let last = conversation.lastActive { line += ", last worked on \(day(last))" }
            if let files = conversation.files { line += ". Its files are in `\(files)`" }
            lines.append(line)
        }
        lines += ["", "`\(Importer.sidecarRootName)/Brief for a new project.md` says where each one got to.", ""]
        return lines.joined(separator: "\n")
    }

    static func briefText(name: String, space: SpaceRef?, briefs: [String], now: Date) -> String {
        var lines = ["# \(name)", "",
                     "Where this project got to as Cowork tasks, written \(day(now)) to start a new project from. Attach it to the new project's first message.", ""]
        if let summary = space?.summary { lines += [summary, ""] }
        if let instructions = space?.instructions { lines += ["## Instructions", "", instructions, ""] }
        for brief in briefs {
            lines += ["---", "", SecretSweep.redact(brief), ""]
        }
        if briefs.isEmpty { lines += ["No brief could be written. The conversations are in this folder, ready to resume.", ""] }
        return lines.joined(separator: "\n")
    }

    /// The newest Code tab record under `root`, to start new ones from.
    static func codeTabTemplate(in root: URL) -> (directory: URL, template: URL)? {
        let fm = FileManager.default
        var newest: (URL, Date)?
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if newest == nil || date > newest!.1 { newest = (file, date) }
                }
            }
        }
        return newest.map { ($0.0.deletingLastPathComponent(), $0.0) }
    }

    /// A Code tab record for a conversation brought in, started from another record so it keeps
    /// that app's model, permission mode and tools, with everything about the other one dropped.
    static func writeCodeTabRecord(copying template: URL, into directory: URL, cliSessionId: String,
                                   title: String, cwd: String) throws -> URL {
        var record = try JSONValue.parse(try Data(contentsOf: template))
        guard case .object = record else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: template.path]) }
        let localId = "local_" + UUID().uuidString.lowercased()
        let now = JSONValue.int(Int64(Date().timeIntervalSince1970 * 1000))
        record["sessionId"] = .string(localId)
        record["cliSessionId"] = .string(cliSessionId)
        record["title"] = .string(title)
        record["titleSource"] = .string("user")
        record["cwd"] = .string(cwd)
        record["originCwd"] = .string(cwd)
        for key in ["createdAt", "lastActivityAt", "lastFocusedAt"] { record[key] = now }
        if record["isArchived"] != nil { record["isArchived"] = .bool(false) }
        if record["isStarred"] != nil { record["isStarred"] = .bool(false) }
        for key in ["previousTitles", "gitAnchors", "writtenBranches", "publishedArtifacts",
                    "alwaysAllowedReasons", "sessionPermissionUpdates"] where record[key] != nil {
            record[key] = .array([])
        }
        for key in ["postTurnSummary", "postTurnSummaryFor", "lastAssistantUuid", "latestUserFrameAt",
                    "completedTurns", "titleTurn", "transcriptUnavailable", "spawnSeed",
                    "promptAppendSnapshot", "toolSurfaceSnapshot", "worktreePath", "worktreeName"] {
            record[key] = nil
        }
        let url = directory.appendingPathComponent("\(localId).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw TransferError.destinationExists(url) }
        try AtomicWrite.write(record.serialized(), to: url)
        return url
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day())
    }
}
