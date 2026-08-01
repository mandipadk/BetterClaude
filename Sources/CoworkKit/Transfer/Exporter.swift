import Foundation

public struct ExportOptions: Sendable {
    public var redactionProfile: RedactionProfile
    /// The user's source documents. Off by default: they are large and personal, and the
    /// chat itself is what the transfer is for.
    public var includeUploads: Bool
    /// The session's work product.
    public var includeOutputs: Bool
    /// Applied to `uploads/` and `outputs/`. `node_modules` alone accounts for the large
    /// majority of output files and carries no user value.
    public var extraExclusions: [String]

    public init(redactionProfile: RedactionProfile = .sameUser,
                includeUploads: Bool = false,
                includeOutputs: Bool = false,
                extraExclusions: [String] = ["node_modules", ".DS_Store", ".git"]) {
        self.redactionProfile = redactionProfile
        self.includeUploads = includeUploads
        self.includeOutputs = includeOutputs
        self.extraExclusions = extraExclusions
    }
}

public struct ExportPlan: Sendable {
    public let slots: [BundleWriter.SlotInput]
    public let warnings: [String]
    public let totalBytes: Int64
    public var sessionCount: Int { slots.count }
}

public enum Exporter {

    // MARK: - Cowork sources

    public static func plan(_ sessions: [SessionRef], options: ExportOptions) throws -> ExportPlan {
        var slots: [BundleWriter.SlotInput] = []
        var warnings: [String] = []
        var total: Int64 = 0

        for session in sessions {
            guard let transcriptURL = session.transcriptURL else {
                throw TransferError.sourceTranscriptMissing(sessionId: session.sessionId)
            }
            let transcript = try Transcript(contentsOf: transcriptURL)
            let stats = transcript.stats()
            if stats.orphanParentUuids > 0 {
                warnings.append("\(session.title): \(stats.orphanParentUuids) records reference a missing parent")
            }

            let doc = try MetadataDocument(contentsOf: session.metadataURL)
            let (redacted, redactionNotes) = redact(doc, profile: options.redactionProfile)
            warnings.append(contentsOf: redactionNotes.map { "\(session.title): \($0)" })

            let workspaceRoot = session.workspaceURL.path
            let vmPath = "/sessions/\(session.processName)"
            let occurrences = RewriteEngine.countOccurrences(
                of: [workspaceRoot, vmPath], in: transcript.records)

            var extras: [(relativePath: String, source: URL)] = []
            extras.append(contentsOf: collectSubagents(session: session))
            extras.append(contentsOf: collectMemory(session: session))
            if options.includeUploads {
                extras.append(contentsOf: collect(dir: session.workspaceURL.appendingPathComponent("uploads"),
                                                  as: "uploads", options: options))
            }
            if options.includeOutputs {
                extras.append(contentsOf: collect(dir: session.workspaceURL.appendingPathComponent("outputs"),
                                                  as: "outputs", options: options))
            }
            if !options.includeUploads || !options.includeOutputs {
                let omitted = missingReferencedFiles(transcript: transcript, session: session, options: options)
                if !omitted.isEmpty {
                    let noun = omitted.count == 1 ? "file" : "files"
                    warnings.append("\(session.title): \(omitted.count) \(noun) referenced by this conversation will not be included")
                }
            }

            let (title, titleSource) = transcript.resolvedTitle()
            let origin = Manifest.Origin(
                kind: "cowork",
                variantDirName: session.account.store.variantDirName,
                sessionId: session.sessionId,
                cliSessionId: session.cliSessionId,
                processName: session.processName,
                cwd: session.cwd,
                hostLoopMode: session.hostLoopMode,
                model: session.model,
                createdAt: session.createdAt,
                lastActivityAt: session.lastActivityAt,
                gitBranchOriginal: stats.gitBranchesSeen.first,
                entrypointsSeen: stats.entrypointsSeen)

            let chat = summary(from: stats, title: session.title.isEmpty ? title : session.title,
                               titleSource: titleSource)
            let pathMap = Manifest.PathMap(workspaceRoot: workspaceRoot,
                                           vmSessionPath: vmPath,
                                           occurrences: occurrences)

            total += session.byteSize
            for extra in extras { total += fileSize(extra.source) }

            slots.append(BundleWriter.SlotInput(
                origin: origin, chat: chat, pathMap: pathMap,
                metadata: redacted.root, transcript: transcript.serializedData(), extraFiles: extras))
        }
        return ExportPlan(slots: slots, warnings: warnings, totalBytes: total)
    }

    // MARK: - Claude Code sources

    public static func plan(_ sessions: [CCSessionRef], options: ExportOptions) throws -> ExportPlan {
        var slots: [BundleWriter.SlotInput] = []
        var warnings: [String] = []
        var total: Int64 = 0

        for session in sessions {
            let transcript = try Transcript(contentsOf: session.transcriptURL)
            let stats = transcript.stats()
            if stats.orphanParentUuids > 0 {
                warnings.append("\(session.title): \(stats.orphanParentUuids) records reference a missing parent")
            }
            let (title, titleSource) = transcript.resolvedTitle()

            let origin = Manifest.Origin(
                kind: "claudeCode",
                variantDirName: nil,
                sessionId: nil,
                cliSessionId: session.sessionId,
                processName: nil,
                cwd: session.resolvedCwd,
                hostLoopMode: nil,
                model: nil,
                createdAt: session.firstTimestamp,
                lastActivityAt: session.lastTimestamp,
                gitBranchOriginal: stats.gitBranchesSeen.first,
                entrypointsSeen: stats.entrypointsSeen)

            let occurrences = RewriteEngine.countOccurrences(of: [session.resolvedCwd], in: transcript.records)
            let pathMap = Manifest.PathMap(workspaceRoot: session.resolvedCwd,
                                           vmSessionPath: nil,
                                           occurrences: occurrences)

            var extras: [(relativePath: String, source: URL)] = []
            let subagentDir = session.projectDir
                .appendingPathComponent(session.sessionId)
                .appendingPathComponent("subagents")
            extras.append(contentsOf: collect(dir: subagentDir, as: "subagents", options: options))

            total += session.byteSize
            slots.append(BundleWriter.SlotInput(
                origin: origin,
                chat: summary(from: stats, title: title, titleSource: titleSource),
                pathMap: pathMap, metadata: nil,
                transcript: transcript.serializedData(), extraFiles: extras))
        }
        return ExportPlan(slots: slots, warnings: warnings, totalBytes: total)
    }

    public static func write(_ plan: ExportPlan, to url: URL,
                             profile: RedactionProfile = .sameUser) throws -> Manifest {
        try BundleWriter.write(slots: plan.slots, to: url, profile: profile, warnings: plan.warnings)
    }

    // MARK: - Redaction

    /// Strips what must never travel, regardless of profile, then applies profile-specific
    /// identity redaction.
    ///
    /// Two categories are dropped unconditionally. Security-posture fields
    /// (`permissionMode: bypassPermissions`, `chromePermissionMode: skip_all_permission_checks`,
    /// granted computer-use apps) would silently hand the destination a more permissive
    /// session than the user would have created there. Privacy fields (`fsDetectedFiles`,
    /// `mcqAnswers`, `webFetchAllowedUrls`) disclose host directory names and personal
    /// answers that no transfer needs.
    ///
    /// `systemPrompt` is always omitted: it is 40+ KB of destination-build boilerplate, so
    /// carrying it forward would pin an imported session to the *source* app's build. The
    /// importer takes the destination's own copy instead.
    static func redact(_ doc: MetadataDocument, profile: RedactionProfile) -> (MetadataDocument, [String]) {
        var out = doc
        var notes: [String] = []

        for key in MetadataDocument.securityPostureKeys where out.root[key] != nil {
            if key == "permissionMode" || key == "chromePermissionMode",
               let value = out.root[key]?.stringValue,
               value != "default" && value != "follow_a_plan" {
                notes.append("dropped permissive \(key) (\(value))")
            }
            out.root[key] = nil
        }
        for key in MetadataDocument.privacyKeys where out.root[key] != nil {
            out.root[key] = nil
        }
        if let egress = out.root["egressAllowedDomains"]?.arrayValue,
           egress.contains(where: { $0.stringValue == "*" }) {
            notes.append("source session allowed unrestricted network egress; not carried forward")
            out.root["egressAllowedDomains"] = nil
        }
        if out.root["systemPrompt"] != nil {
            out.root["systemPrompt"] = nil
        }
        // Tool schemas are the bulk of the file and are rebuilt from the destination's own
        // connector installs; the server identities are kept so the UI can report them.
        if var servers = out.root["remoteMcpServersConfig"]?.arrayValue {
            for i in servers.indices { servers[i]["tools"] = nil }
            out.root["remoteMcpServersConfig"] = .array(servers)
        }

        switch profile {
        case .sameUser:
            break
        case .crossUser, .share:
            out.emailAddress = nil
            out.accountName = nil
            out.root["spaceId"] = nil
            out.root["spaceIdSetBy"] = nil
            notes.append("identity fields removed for \(profile.rawValue) profile")
        }
        if profile == .share {
            out.root["slashCommands"] = nil
            out.root["enabledMcpTools"] = nil
            out.root["remoteMcpServersConfig"] = nil
            out.root["orgCliExecPolicies"] = nil
        }
        return (out, notes)
    }

    // MARK: - File collection

    static func summary(from stats: ChatStats, title: String, titleSource: TitleSource) -> Manifest.ChatSummary {
        Manifest.ChatSummary(
            title: title, titleSource: titleSource.rawValue,
            recordCount: stats.recordCount, chainRecordCount: stats.chainRecordCount,
            userTurns: stats.userTurns, assistantTurns: stats.assistantTurns,
            orphanParentUuids: stats.orphanParentUuids,
            inlineMediaBlocks: stats.inlineMediaBlocks, inlineMediaBytes: stats.inlineMediaBytes,
            firstTimestamp: stats.firstTimestamp, lastTimestamp: stats.lastTimestamp)
    }

    static func collectSubagents(session: SessionRef) -> [(relativePath: String, source: URL)] {
        guard let projectDir = session.projectDirURL else { return [] }
        var result: [(String, URL)] = []
        let nested = projectDir.appendingPathComponent(session.cliSessionId).appendingPathComponent("subagents")
        result.append(contentsOf: collect(dir: nested, as: "subagents", options: nil))
        if result.isEmpty,
           let entries = try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) {
            for entry in entries
            where entry.lastPathComponent.hasPrefix("agent-") && entry.pathExtension == "jsonl" {
                result.append(("subagents/\(entry.lastPathComponent)", entry))
            }
        }
        return result.map { (relativePath: $0.0, source: $0.1) }
    }

    static func collectMemory(session: SessionRef) -> [(relativePath: String, source: URL)] {
        guard let projectDir = session.projectDirURL else { return [] }
        return collect(dir: projectDir.appendingPathComponent("memory"), as: "memory", options: nil)
            .map { (relativePath: $0.relativePath, source: $0.source) }
    }

    static func collect(dir: URL, as prefix: String, options: ExportOptions?) -> [(relativePath: String, source: URL)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let exclusions = options?.extraExclusions ?? [".DS_Store"]

        var result: [(relativePath: String, source: URL)] = []
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: [])
        else { return [] }
        for case let url as URL in walker {
            let relative = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            if exclusions.contains(where: { relative.split(separator: "/").contains(Substring($0)) }) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Symlinks are never followed out of a session workspace.
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            result.append((relativePath: "\(prefix)/\(relative)", source: url))
        }
        return result
    }

    /// Absolute paths the conversation refers to that the chosen options will not include.
    static func missingReferencedFiles(transcript: Transcript, session: SessionRef,
                                       options: ExportOptions) -> [String] {
        var roots: [String] = []
        if !options.includeUploads { roots.append(session.workspaceURL.appendingPathComponent("uploads").path) }
        if !options.includeOutputs { roots.append(session.workspaceURL.appendingPathComponent("outputs").path) }
        guard !roots.isEmpty else { return [] }
        let counts = RewriteEngine.countOccurrences(of: roots, in: transcript.records)
        return counts.filter { $0.value > 0 }.map(\.key)
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
}
