import Foundation

public struct ImportOptions: Sendable {
    /// Mint a new transcript id even when the original is free. Forced automatically on
    /// collision.
    public var regenerateCliSessionId: Bool
    /// Write only the field set that every observed Cowork build understands. Use when a
    /// destination app is older than the source and rejects the session.
    public var minimalMetadata: Bool
    /// Import into an account that currently has no sessions. Off by default: Claude Desktop
    /// only ever reads the account it is signed into, so importing into the wrong one
    /// produces a session that exists on disk and is invisible forever.
    public var allowEmptyAccount: Bool
    /// Quit a conflicting Claude instance rather than refusing.
    public var quitRunningVariant: Bool

    public init(regenerateCliSessionId: Bool = false,
                minimalMetadata: Bool = false,
                allowEmptyAccount: Bool = false,
                quitRunningVariant: Bool = false) {
        self.regenerateCliSessionId = regenerateCliSessionId
        self.minimalMetadata = minimalMetadata
        self.allowEmptyAccount = allowEmptyAccount
        self.quitRunningVariant = quitRunningVariant
    }
}

/// Everything derived for one session before a single byte is written.
public struct SlotComputation: Sendable {
    public let slot: String
    public let title: String
    /// `local_<uuid>` for Cowork destinations; `nil` for Claude Code.
    public let newSessionId: String?
    /// The transcript's UUID — the filename stem, which is what `--resume <id>` matches.
    public let cliSessionId: String
    public let processName: String?
    public let newCwd: String
    public let encodedProjectDir: String
    public let transcriptURL: URL
    public let workspaceURL: URL?
    public let rewriteMap: RewriteMap
}

public struct ImportPlan: Sendable {
    public let direction: TransferDirection
    public let bundleURL: URL
    public let manifest: Manifest
    public let endpoint: Endpoint
    public let preconditions: [PreconditionResult]
    public let willCreate: [URL]
    /// Must be empty for every normal import — this tool creates, it does not overwrite.
    public let willModify: [URL]
    public let computed: [SlotComputation]
    public let conflicts: [RunningVariant]

    public var isExecutable: Bool { preconditions.allSatisfy(\.passed) }
    public var failures: [String] {
        preconditions.filter { !$0.passed }.map { "[\($0.id)] \($0.title)" + ($0.detail.map { ": \($0)" } ?? "") }
    }
}

public enum Importer {

    // MARK: - Plan

    public static func plan(bundle bundleURL: URL, to endpoint: Endpoint,
                            options: ImportOptions = ImportOptions()) throws -> ImportPlan {
        let manifest = try BundleReader.openManifest(at: bundleURL)
        var checks: [PreconditionResult] = []

        checks.append(PreconditionResult(
            id: "PC6", title: "Bundle format is readable by this version",
            passed: manifest.bundleVersion <= Manifest.currentVersion,
            detail: manifest.bundleVersion > Manifest.currentVersion
                ? "bundle is version \(manifest.bundleVersion), this build supports \(Manifest.currentVersion)" : nil))

        let integrityProblems = (try? BundleReader.verify(at: bundleURL)) ?? ["bundle could not be verified"]
        checks.append(PreconditionResult(
            id: "PC6b", title: "Every file matches its recorded checksum",
            passed: integrityProblems.isEmpty,
            detail: integrityProblems.first))

        let scan = try? BundleReader.openScanReport(at: bundleURL)
        checks.append(PreconditionResult(
            id: "PC7", title: "Bundle carries no credential-shaped content",
            passed: scan?.status != .block,
            detail: scan?.status == .block ? "\(scan?.findings.count ?? 0) blocking finding(s)" : nil))

        let brokenChains = manifest.sessions.filter { $0.chat.orphanParentUuids > 0 }
        checks.append(PreconditionResult(
            id: "PC8", title: "Conversation chains are intact",
            passed: brokenChains.isEmpty,
            detail: brokenChains.first.map { "slot \($0.slot) has \($0.chat.orphanParentUuids) orphaned records" }))

        let conflicts = (try? Guards.conflicts(with: endpoint)) ?? []
        checks.append(PreconditionResult(
            id: "PC2", title: "No Claude instance is running against the destination",
            passed: conflicts.isEmpty || options.quitRunningVariant,
            detail: conflicts.isEmpty ? nil
                : "running: " + conflicts.map { "pid \($0.pid) → \($0.userDataDir.lastPathComponent)" }.joined(separator: ", ")))

        switch endpoint {
        case .cowork(let account):
            return try planIntoCowork(bundleURL: bundleURL, manifest: manifest, account: account,
                                      options: options, checks: &checks, conflicts: conflicts)
        case .claudeCode(let projectDir, let configDir):
            return try planIntoClaudeCode(bundleURL: bundleURL, manifest: manifest,
                                          projectDir: projectDir, configDir: configDir,
                                          options: options, checks: &checks, conflicts: conflicts)
        }
    }

    // MARK: - Plan: destination is Cowork

    static func planIntoCowork(bundleURL: URL, manifest: Manifest, account: AccountRef,
                               options: ImportOptions, checks: inout [PreconditionResult],
                               conflicts: [RunningVariant]) throws -> ImportPlan {
        let fm = FileManager.default
        checks.append(PreconditionResult(
            id: "PC1", title: "Destination account directory exists",
            passed: fm.fileExists(atPath: account.root.path),
            detail: account.root.path))

        let donor = try donorSession(in: account)
        let anyFromClaudeCode = manifest.sessions.contains { $0.origin.kind == Manifest.Origin.kindClaudeCode }
        checks.append(PreconditionResult(
            id: "PC9", title: "Account has an existing session to copy app settings from",
            passed: donor != nil || !anyFromClaudeCode,
            detail: donor == nil && anyFromClaudeCode
                ? "sign in and open one session in \(account.store.variantDirName) first" : nil))

        // This check always meant "will Claude Desktop actually read what we write here", and
        // used an empty session list as a proxy for "never signed in". That proxy is wrong in
        // the one case that matters most: an install you just signed into has no sessions and
        // is exactly where you would want to send a conversation. `isSignedIn` reads the
        // install's own record instead of guessing from emptiness.
        //
        // Still a union rather than `isSignedIn` alone: a store records one signed-in account,
        // so a second account that already holds conversations would otherwise start failing a
        // check it has always passed.
        checks.append(PreconditionResult(
            id: "PC9b", title: "Account is one Claude Desktop will read",
            passed: account.canReceiveTransfer || options.allowEmptyAccount,
            detail: account.canReceiveTransfer
                ? nil
                : "\(account.store.variantDirName) is not signed into this account and it holds "
                  + "no conversations, so an import here would be invisible rather than broken"))

        // What will happen to each incoming conversation's Project, stated before anything is
        // written. A folder that no longer exists is worth knowing about here rather than
        // discovering as a project that connects to nothing.
        let existingSpaces = SpaceStore.spaces(inOrg: account.root)
        var missingFolders: [String] = []
        var spacesToCreate: [String] = []
        for entry in manifest.sessions {
            guard let space = entry.space else { continue }
            if case .absent = SpaceStore.match(space, against: existingSpaces) {
                spacesToCreate.append(space.name)
            }
            for folder in space.folders
            where !fm.fileExists(atPath: folder) {
                missingFolders.append(folder)
            }
        }
        if !spacesToCreate.isEmpty {
            checks.append(PreconditionResult(
                id: "PC12", title: "Project will be created in the destination",
                passed: true,
                detail: spacesToCreate.joined(separator: ", ")))
        }
        if !missingFolders.isEmpty {
            // Informational, not blocking. The conversation transfers perfectly well; it is
            // the project's folder that will connect to nothing, and the person who moved the
            // folder is the only one who can fix that.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            checks.append(PreconditionResult(
                id: "PC13", title: "A project folder no longer exists on this Mac",
                passed: true,
                detail: missingFolders
                    .map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
                    .joined(separator: ", ")))
        }

        var takenNames = ProcessName.namesInUse(at: account.root)
        var computed: [SlotComputation] = []
        var willCreate: [URL] = []

        for entry in manifest.sessions {
            let newSessionId = "\(StoreLayout.sessionPrefix)\(UUID().uuidString.lowercased())"
            let processName = ProcessName.mint(avoiding: takenNames)
            takenNames.insert(processName)

            let workspace = account.root.appendingPathComponent(newSessionId, isDirectory: true)
            // Invariant R4, which holds across every observed session: a host-loop session's
            // cwd is its own `outputs` directory, and a VM session's is `/sessions/<name>`.
            let hostLoop = entry.origin.hostLoopMode ?? (entry.origin.kind == Manifest.Origin.kindClaudeCode)
            let newCwd = hostLoop
                ? workspace.appendingPathComponent("outputs").path
                : "/sessions/\(processName)"
            let encoded = PathEncoder.encode(newCwd)

            var cliSessionId = entry.origin.cliSessionId ?? UUID().uuidString.lowercased()
            if options.regenerateCliSessionId || !StoreLayout.isFullUUID(cliSessionId) {
                cliSessionId = UUID().uuidString.lowercased()
            }

            let projectDir = workspace
                .appendingPathComponent(".claude/projects", isDirectory: true)
                .appendingPathComponent(encoded, isDirectory: true)
            let transcriptURL = projectDir.appendingPathComponent("\(cliSessionId).jsonl")

            let map = RewriteMap.forWorkspaceMove(
                oldWorkspaceRoot: entry.pathMap.workspaceRoot ?? "",
                newWorkspaceRoot: workspace.path,
                oldProcessName: entry.origin.processName ?? "",
                newProcessName: processName)

            computed.append(SlotComputation(
                slot: entry.slot, title: entry.chat.title, newSessionId: newSessionId,
                cliSessionId: cliSessionId, processName: processName, newCwd: newCwd,
                encodedProjectDir: encoded, transcriptURL: transcriptURL,
                workspaceURL: workspace, rewriteMap: map))

            willCreate.append(workspace)
            willCreate.append(account.root.appendingPathComponent("\(newSessionId).json"))
        }

        checks.append(PreconditionResult(
            id: "PC4", title: "Enough free space on the destination volume",
            passed: hasSpace(for: bundleURL, at: account.root),
            detail: nil))

        let direction: TransferDirection = anyFromClaudeCode ? .codeToCowork : .coworkToCowork
        return ImportPlan(direction: direction, bundleURL: bundleURL, manifest: manifest,
                          endpoint: .cowork(account), preconditions: checks,
                          willCreate: willCreate, willModify: [], computed: computed,
                          conflicts: conflicts)
    }

    // MARK: - Plan: destination is Claude Code

    static func planIntoClaudeCode(bundleURL: URL, manifest: Manifest, projectDir: URL,
                                   configDir: URL, options: ImportOptions,
                                   checks: inout [PreconditionResult],
                                   conflicts: [RunningVariant]) throws -> ImportPlan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let projectExists = fm.fileExists(atPath: projectDir.path, isDirectory: &isDir) && isDir.boolValue
        checks.append(PreconditionResult(
            id: "PC10", title: "Target project directory exists",
            passed: projectExists, detail: projectDir.path))

        // Importing into a directory that is itself part of a transcript store would create a
        // project whose encoded name refers back into the store — confusing and unresolvable.
        checks.append(PreconditionResult(
            id: "PC10b", title: "Target is not inside a Claude Code store",
            passed: !projectDir.path.contains("/.claude/projects/"),
            detail: nil))

        let realProjectPath = PathEncoder.resolvedPath(projectDir.path)
        let encoded = PathEncoder.encode(realProjectPath)
        let projectsRoot = configDir.appendingPathComponent("projects", isDirectory: true)
        let encodedDir = projectsRoot.appendingPathComponent(encoded, isDirectory: true)

        var computed: [SlotComputation] = []
        var willCreate: [URL] = []
        var used = Set((try? fm.contentsOfDirectory(atPath: encodedDir.path))?
            .filter { StoreLayout.isTranscriptFileName($0) }
            .map { String($0.dropLast(6)) } ?? [])

        for entry in manifest.sessions {
            var sessionId = entry.origin.cliSessionId ?? UUID().uuidString.lowercased()
            if options.regenerateCliSessionId || used.contains(sessionId) || !StoreLayout.isFullUUID(sessionId) {
                sessionId = UUID().uuidString.lowercased()
            }
            used.insert(sessionId)

            let transcriptURL = encodedDir.appendingPathComponent("\(sessionId).jsonl")
            let map = RewriteMap(orderedRules: [
                (from: entry.pathMap.workspaceRoot ?? "", to: importSidecarDir(in: projectDir, slot: entry.slot).path),
                (from: entry.pathMap.vmSessionPath ?? "", to: realProjectPath),
            ].filter { !$0.from.isEmpty })

            computed.append(SlotComputation(
                slot: entry.slot, title: entry.chat.title, newSessionId: nil,
                cliSessionId: sessionId, processName: nil, newCwd: realProjectPath,
                encodedProjectDir: encoded, transcriptURL: transcriptURL,
                workspaceURL: nil, rewriteMap: map))
            willCreate.append(transcriptURL)
        }

        checks.append(PreconditionResult(
            id: "PC11", title: "Encoded project directory name is within filesystem limits",
            passed: encoded.utf8.count <= 255, detail: nil))
        checks.append(PreconditionResult(
            id: "PC4", title: "Enough free space on the destination volume",
            passed: hasSpace(for: bundleURL, at: configDir), detail: nil))

        return ImportPlan(direction: .coworkToCode, bundleURL: bundleURL, manifest: manifest,
                          endpoint: .claudeCode(projectDir: projectDir, configDir: configDir),
                          preconditions: checks, willCreate: willCreate, willModify: [],
                          computed: computed, conflicts: conflicts)
    }

    // MARK: - Apply

    public static func apply(_ plan: ImportPlan,
                             options: ImportOptions = ImportOptions(),
                             progress: (@Sendable (String) -> Void)? = nil) throws -> ImportReceipt {
        guard plan.isExecutable else { throw TransferError.preconditionsFailed(plan.failures) }

        if !plan.conflicts.isEmpty {
            guard options.quitRunningVariant else { throw TransferError.variantRunning(plan.conflicts) }
            for variant in plan.conflicts {
                progress?("Quitting Claude (pid \(variant.pid))…")
                try Guards.quit(variant, timeout: 30)
            }
        }

        var receipt = ImportReceipt(
            direction: plan.direction,
            bundlePath: plan.bundleURL.path,
            bundleSha256: nil,
            destination: plan.endpoint.describedDestination)
        try Undo.save(receipt)

        do {
            switch plan.endpoint {
            case .cowork(let account):
                try applyIntoCowork(plan, account: account, options: options,
                                    receipt: &receipt, progress: progress)
            case .claudeCode(let projectDir, _):
                try applyIntoClaudeCode(plan, projectDir: projectDir, options: options,
                                        receipt: &receipt, progress: progress)
            }
        } catch {
            try? Undo.save(receipt)
            throw error
        }

        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }

    /// Work out which Project each incoming conversation should belong to here.
    ///
    /// A space id is only meaningful inside the organisation that defined it, so a conversation
    /// arriving from another install names a project this organisation has never heard of. Left
    /// alone the id dangles and Claude Desktop reports the folder as no longer connected —
    /// which is exactly what it did.
    ///
    /// Three outcomes, in order of preference: the same project is already here and is reused;
    /// a project with the same name and folders is here under a different id, so the session is
    /// pointed at that one rather than creating a duplicate with an identical name; or nothing
    /// like it exists and it is created. A conversation whose project could not travel — any
    /// profile but `sameUser` — resolves to `nil`, which clears the id rather than leaving it
    /// pointing at nothing.
    ///
    /// Returns slot → space id. A missing entry means "clear it".
    static func resolveSpaces(_ plan: ImportPlan, account: AccountRef,
                              receipt: inout ImportReceipt) throws -> [String: String?] {
        var resolved: [String: String?] = [:]
        var known = SpaceStore.spaces(inOrg: account.root)
        var created: [ImportReceipt.CreatedSpace] = []

        for entry in plan.manifest.sessions {
            guard let space = entry.space else { continue }
            switch SpaceStore.match(space, against: known) {
            case .sameId(let existing), .equivalent(let existing):
                resolved[entry.slot] = existing.id
            case .absent:
                try SpaceStore.add(space, toOrg: account.root)
                known.append(space)
                created.append(ImportReceipt.CreatedSpace(
                    spaceId: space.id, orgRoot: account.root.path, name: space.name))
                resolved[entry.slot] = space.id
                // Only for a project brought into being here. A project that already existed
                // has its own memory, written by conversations that live in it, and copying
                // over that would destroy work this transfer has no claim on.
                try installSpaceMemory(slot: entry.slot, plan: plan, spaceId: space.id,
                                       account: account, receipt: &receipt)
            }
        }
        if !created.isEmpty { receipt.createdSpaces = created }
        return resolved
    }

    /// Put a carried project's memory in place, for a project this import created.
    ///
    /// A project's memory is what it has learned across every conversation in it. Without it a
    /// conversation arrives in a project that has forgotten everything it knew.
    static func installSpaceMemory(slot: String, plan: ImportPlan, spaceId: String,
                                   account: AccountRef, receipt: inout ImportReceipt) throws {
        let fm = FileManager.default
        let source = BundleReader.slotURL(slot, in: plan.bundleURL)
            .appendingPathComponent(BundleLayout.spaceMemoryDirName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return }

        let destination = account.root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        // Create-only, like every other write this tool makes.
        guard !fm.fileExists(atPath: destination.path) else { return }

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        // Fingerprinted, so undo refuses to delete anything edited since the import.
        try receipt.recordCreatedTree(at: destination)
    }

    static func applyIntoCowork(_ plan: ImportPlan, account: AccountRef, options: ImportOptions,
                                receipt: inout ImportReceipt,
                                progress: (@Sendable (String) -> Void)?) throws {
        let fm = FileManager.default
        let donor = try donorSession(in: account)
        let spaceIds = try resolveSpaces(plan, account: account, receipt: &receipt)

        for computation in plan.computed {
            guard let workspace = computation.workspaceURL,
                  let newSessionId = computation.newSessionId,
                  let processName = computation.processName,
                  let entry = plan.manifest.sessions.first(where: { $0.slot == computation.slot })
            else { continue }
            progress?("Importing \(computation.title)…")

            let slotDir = BundleReader.slotURL(computation.slot, in: plan.bundleURL)
            let metadataDestination = account.root.appendingPathComponent("\(newSessionId).json")
            guard !fm.fileExists(atPath: metadataDestination.path) else {
                throw TransferError.destinationExists(metadataDestination)
            }

            // Build the whole workspace under a dot-prefixed staging name in the destination
            // directory, then move it in one rename. Claude Desktop's session scan filters on
            // a `local_` prefix, so a staging directory is invisible to it even mid-write.
            let staging = account.root.appendingPathComponent(
                AtomicWrite.temporaryName(prefix: ".betterclaude-import"), isDirectory: true)
            try AtomicWrite.ensureSameVolume(staging, account.root)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            let stagedProjectDir = staging
                .appendingPathComponent(".claude/projects", isDirectory: true)
                .appendingPathComponent(computation.encodedProjectDir, isDirectory: true)
            try fm.createDirectory(at: stagedProjectDir, withIntermediateDirectories: true)
            // `outputs` is the working directory in host-loop mode and must exist even empty.
            try fm.createDirectory(at: staging.appendingPathComponent("outputs"), withIntermediateDirectories: true)
            try fm.createDirectory(at: staging.appendingPathComponent("uploads"), withIntermediateDirectories: true)

            var transcript = try Transcript(contentsOf: slotDir.appendingPathComponent("transcript.jsonl"))
            let rewritten = RewriteEngine.apply(computation.rewriteMap, to: transcript.records)
            transcript = Transcript(records: rewritten.0)
            transcript.mapRecords { record in
                var r = record
                if r["cwd"] != nil { r["cwd"] = .string(computation.newCwd) }
                if r["sessionId"] != nil { r["sessionId"] = .string(computation.cliSessionId) }
                if r["session_id"] != nil { r["session_id"] = .string(computation.cliSessionId) }
                // Every observed Cowork transcript uses these two values; matching them keeps
                // an imported session inside shapes the app has actually seen.
                if r["entrypoint"] != nil { r["entrypoint"] = .string("local-agent") }
                if r["gitBranch"] != nil { r["gitBranch"] = .string("HEAD") }
                if let type = r["type"]?.stringValue, Self.sidecarTypesToDrop.contains(type) { return nil }
                return r
            }
            try transcript.write(to: stagedProjectDir.appendingPathComponent("\(computation.cliSessionId).jsonl"))

            try copyExtras(from: slotDir, into: staging, projectDir: stagedProjectDir,
                           cliSessionId: computation.cliSessionId)

            let metadata = try buildCoworkMetadata(
                entry: entry, slotDir: slotDir, donor: donor, account: account,
                computation: computation, processName: processName,
                newSessionId: newSessionId, minimal: options.minimalMetadata,
                transcript: transcript,
                spaceId: spaceIds[computation.slot] ?? nil,
                profile: plan.manifest.redactionProfile)

            // Workspace first, metadata last. Claude Desktop's janitor deletes workspace
            // directories that no session file claims, so a metadata file that appears before
            // its workspace is the one ordering that can lose data.
            let workspaceDestination = workspace
            guard !fm.fileExists(atPath: workspaceDestination.path) else {
                throw TransferError.destinationExists(workspaceDestination)
            }
            try AtomicWrite.replaceDirectory(stagedAt: staging, with: workspaceDestination)
            receipt.created.append(.init(path: workspaceDestination.path, isDirectory: true, sha256: nil))

            try metadata.write(to: metadataDestination)
            receipt.created.append(.init(path: metadataDestination.path, isDirectory: false,
                                         sha256: try? FileDigest.hex(contentsOf: metadataDestination)))
            try Undo.save(receipt)
        }
    }

    static func applyIntoClaudeCode(_ plan: ImportPlan, projectDir: URL, options: ImportOptions,
                                    receipt: inout ImportReceipt,
                                    progress: (@Sendable (String) -> Void)?) throws {
        let fm = FileManager.default
        for computation in plan.computed {
            progress?("Importing \(computation.title)…")
            let slotDir = BundleReader.slotURL(computation.slot, in: plan.bundleURL)
            let encodedDir = computation.transcriptURL.deletingLastPathComponent()
            let createdEncodedDir = !fm.fileExists(atPath: encodedDir.path)
            try fm.createDirectory(at: encodedDir, withIntermediateDirectories: true)
            if createdEncodedDir {
                receipt.created.append(.init(path: encodedDir.path, isDirectory: true, sha256: nil))
            }
            guard !fm.fileExists(atPath: computation.transcriptURL.path) else {
                throw TransferError.destinationExists(computation.transcriptURL)
            }

            var transcript = try Transcript(contentsOf: slotDir.appendingPathComponent("transcript.jsonl"))
            let sidecar = importSidecarDir(in: projectDir, slot: computation.slot)
            let rewritten = RewriteEngine.apply(computation.rewriteMap, to: transcript.records)
            transcript = Transcript(records: rewritten.0)

            let branch = gitBranch(at: computation.newCwd)
            transcript.mapRecords { record in
                var r = record
                if let type = r["type"]?.stringValue, Self.sidecarTypesToDrop.contains(type) { return nil }
                if r["cwd"] != nil { r["cwd"] = .string(computation.newCwd) }
                if r["sessionId"] != nil { r["sessionId"] = .string(computation.cliSessionId) }
                if r["session_id"] != nil { r["session_id"] = .string(computation.cliSessionId) }
                // `sdk-cli` and friends are filtered out of the resume picker entirely.
                if r["entrypoint"] != nil { r["entrypoint"] = .string("cli") }
                if r["gitBranch"] != nil {
                    if let branch { r["gitBranch"] = .string(branch) } else { r["gitBranch"] = nil }
                }
                return r
            }

            // Highest-precedence title source, so the picker shows the conversation's real
            // title rather than the raw first prompt (often a large uploaded-files blob).
            var titleRecord = JSONObject()
            titleRecord["type"] = .string("custom-title")
            titleRecord["customTitle"] = .string(computation.title)
            titleRecord["sessionId"] = .string(computation.cliSessionId)
            transcript = Transcript(records: transcript.records + [.object(titleRecord)])

            let violations = transcript.pickerFilterViolations()
            if !violations.isEmpty { throw TransferError.pickerFilterViolation(violations) }

            try transcript.write(to: computation.transcriptURL)
            receipt.created.append(.init(path: computation.transcriptURL.path, isDirectory: false,
                                         sha256: try? FileDigest.hex(contentsOf: computation.transcriptURL)))

            let extras = (try? fm.contentsOfDirectory(atPath: slotDir.path)) ?? []
            if extras.contains(where: { ["uploads", "outputs", "subagents", "memory"].contains($0) }) {
                try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
                receipt.created.append(.init(path: sidecar.path, isDirectory: true, sha256: nil))
                for name in ["uploads", "outputs", "memory"] where extras.contains(name) {
                    try? fm.copyItem(at: slotDir.appendingPathComponent(name),
                                     to: sidecar.appendingPathComponent(name))
                }
                if extras.contains("subagents") {
                    let dest = encodedDir.appendingPathComponent(computation.cliSessionId)
                        .appendingPathComponent("subagents")
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.copyItem(at: slotDir.appendingPathComponent("subagents"), to: dest)
                    receipt.created.append(.init(path: dest.deletingLastPathComponent().path,
                                                 isDirectory: true, sha256: nil))
                }
            }
            try Undo.save(receipt)
        }
    }

    // MARK: - Helpers

    /// Record types whose payload refers to state that cannot exist at the destination.
    ///
    /// `worktree-state` is the dangerous one: its `originalCwd` overrides project-directory
    /// derivation, which would scope the imported session to a path that does not exist.
    static let sidecarTypesToDrop: Set<String> = [
        "worktree-state", "fork-context-ref", "relocated",
        "file-history-snapshot", "file-history-delta", "frame-link", "pr-link",
    ]

    static func importSidecarDir(in projectDir: URL, slot: String) -> URL {
        projectDir.appendingPathComponent(".better-claude-import", isDirectory: true)
            .appendingPathComponent(slot, isDirectory: true)
    }

    static func copyExtras(from slotDir: URL, into workspace: URL, projectDir: URL,
                           cliSessionId: String) throws {
        let fm = FileManager.default
        for name in ["uploads", "outputs"] {
            let source = slotDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = workspace.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        let subagents = slotDir.appendingPathComponent("subagents")
        if fm.fileExists(atPath: subagents.path) {
            let destination = projectDir.appendingPathComponent(cliSessionId)
                .appendingPathComponent("subagents")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: subagents, to: destination)
        }
        let memory = slotDir.appendingPathComponent("memory")
        if fm.fileExists(atPath: memory.path) {
            try fm.copyItem(at: memory, to: projectDir.appendingPathComponent("memory"))
        }
    }

    /// Any existing session in the account, used as a source for build-specific settings.
    ///
    /// `systemPrompt` in particular is a ~46 KB constant of the destination app's build, not
    /// portable content: carrying the source's copy forward would pin an imported session to
    /// the version of Claude that produced it.
    static func donorSession(in account: AccountRef) throws -> MetadataDocument? {
        let sessions = try Discovery.sessions(in: account)
        guard let newest = sessions.max(by: { $0.lastActivityAt < $1.lastActivityAt }) else { return nil }
        return try? MetadataDocument(contentsOf: newest.metadataURL)
    }

    static func buildCoworkMetadata(entry: Manifest.SessionEntry, slotDir: URL,
                                    donor: MetadataDocument?, account: AccountRef,
                                    computation: SlotComputation, processName: String,
                                    newSessionId: String, minimal: Bool,
                                    transcript: Transcript,
                                    spaceId: String?,
                                    profile: RedactionProfile) throws -> MetadataDocument {
        var doc: MetadataDocument
        let metadataURL = slotDir.appendingPathComponent("metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            doc = try MetadataDocument(contentsOf: metadataURL)
        } else {
            doc = MetadataDocument(root: .object(JSONObject()))
        }

        doc.sessionId = newSessionId
        doc.cliSessionId = computation.cliSessionId
        doc.processName = processName
        doc.vmProcessName = processName
        doc.cwd = computation.newCwd
        doc.hostLoopMode = computation.newCwd.hasPrefix("/sessions/") ? false : true
        doc.title = entry.chat.title
        doc.root["isArchived"] = .bool(false)

        let stats = transcript.stats()
        doc.createdAt = entry.origin.createdAt ?? stats.firstTimestamp ?? Date()
        doc.lastActivityAt = entry.origin.lastActivityAt ?? stats.lastTimestamp ?? Date()
        if doc.root["initialMessage"] == nil {
            doc.root["initialMessage"] = .string(entry.chat.title)
        }
        if doc.root["memoryEnabled"] == nil { doc.root["memoryEnabled"] = .bool(true) }
        // The Project, resolved against this organisation rather than trusted from the bundle.
        // `nil` means the project could not travel, and clearing beats leaving an id that
        // names nothing — a dangling id is what made Claude report the folder as disconnected.
        doc.spaceId = spaceId
        if spaceId == nil { doc.root["spaceIdSetBy"] = nil }

        // Folders the user attached to this specific conversation.
        //
        // These used to be cleared unconditionally, which quietly undid half the point of a
        // same-machine transfer: the folders exist, they belong to the same person, and the
        // conversation is about them. They are absolute host paths, so they only survive a
        // `sameUser` move; anywhere else they would name directories that do not exist and
        // disclose the sender's layout.
        if profile != .sameUser {
            doc.root["userSelectedFolders"] = .array([])
        }
        // Always cleared. This is a permission grant, not a preference: it records paths the
        // source session was allowed to read, and re-granting that silently at the destination
        // would hand over access the user never approved there.
        doc.root["userApprovedFileAccessPaths"] = .array([])

        // Identity always comes from the destination: a session filed under a different
        // account is never read by the app.
        doc.emailAddress = account.emailAddress ?? donor?.emailAddress
        doc.accountName = account.accountName ?? donor?.accountName

        if let donor {
            for key in ["systemPrompt", "slashCommands", "egressAllowedDomains",
                        "memoryGuidelinesTemplate", "systemPromptRendererAppends",
                        "orgCliExecPolicies", "pluginsEnabled", "skillsEnabled"] {
                if let value = donor.root[key] { doc.root[key] = value }
            }
            if doc.model == nil || entry.origin.model == nil {
                doc.model = donor.model
            }
        }
        if let model = entry.origin.model, doc.model == nil { doc.model = model }
        if doc.root["remoteMcpServersConfig"] == nil { doc.root["remoteMcpServersConfig"] = .array([]) }

        if minimal {
            let keep: Set<String> = [
                "sessionId", "cliSessionId", "processName", "vmProcessName", "cwd", "createdAt",
                "lastActivityAt", "title", "initialMessage", "model", "isArchived", "accountName",
                "emailAddress", "systemPrompt", "slashCommands", "egressAllowedDomains",
                "remoteMcpServersConfig", "userSelectedFolders", "hostLoopMode", "memoryEnabled",
                // Kept in the minimal set: the project link is the thing a conversation loses
                // most visibly when it moves, and it is one string.
                "spaceId",
            ]
            if let object = doc.root.objectValue {
                doc.removeKeys(object.keys.filter { !keep.contains($0) })
            }
        }
        return doc
    }

    static func gitBranch(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    static func hasSpace(for bundle: URL, at destination: URL) -> Bool {
        let fm = FileManager.default
        guard let available = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity else { return true }
        var needed: Int64 = 0
        if let walker = fm.enumerator(at: bundle, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                needed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return Int64(available) > needed * 3
    }
}
