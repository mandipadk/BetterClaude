import CoworkKit
import Foundation

// Argument parsing is hand-rolled rather than pulling in swift-argument-parser: the package
// otherwise has no external dependencies, which keeps the app buildable offline.

let usage = """
cowork — move Claude Cowork sessions between Claude Desktop installs and Claude Code

USAGE
  cowork installs
      List every Claude on this Mac, including Parallex copies, Claude Science and
      Claude Code, with how many conversations each holds.

  cowork check-update [--from <version>]
      Find the latest release, download it and verify its signature. Installs nothing.

  cowork storage
      Show where Claude's disk space goes on this Mac, and what can safely be freed.

  cowork stores
      List Claude Desktop installs, their accounts, and session counts.

  cowork list --store <variant> [--account <id>] [--org <id>]
  cowork list --code [--config <dir>] [--project <path>]
      List sessions.

  cowork export <sessionId>... --out <file.coworkbundle>
                [--profile same-user|cross-user|share] [--uploads] [--outputs]
      Export sessions to a bundle. Blocks if credential-shaped content is found.

  cowork inspect <file.coworkbundle>
      Show a bundle's manifest and scan report without extracting it.

  cowork import <file.coworkbundle> --to cowork:<variant>[/<account>/<org>]
  cowork import <file.coworkbundle> --to code:<project-path> [--config <dir>]
                [--dry-run] [--quit-running] [--minimal] [--new-ids]
      Import a bundle. --dry-run prints the plan and writes nothing.

  cowork receipts
  cowork undo <receiptId>
      Review and roll back previous imports.

  cowork encode <path>
      Print the projects/ directory name a path encodes to. Diagnostic.

  cowork index [--rebuild]
      Bring the history index up to date with every conversation on this Mac.

  cowork search <words>... [--limit N]
      Search every message of every conversation, from the index.

  cowork live
      List the Claude Code sessions running now, and whether each is working, idle, or
      waiting for you.

  cowork library [--kind code|document|data|image|upload] [--limit N]
      Harvest every artifact Claude has produced and list them.
"""

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    values[name] = raw[index + 1]
                    index += 2
                    continue
                }
                flags.insert(name)
            } else {
                positional.append(token)
            }
            index += 1
        }
    }
}

func cmdIndex(_ args: Args) throws {
    let url = HistoryIndex.defaultURL()
    if args.flags.contains("rebuild") {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
    let started = Date()
    let (read, summary) = try runBlocking { () -> Result<(Int, HistoryIndex.Summary), Error> in
        do {
            let index = try HistoryIndex(url: url)
            let snapshot = await Catalog().snapshot()
            let read = try await index.update(from: snapshot)
            return .success((read, try await index.summary()))
        } catch { return .failure(error) }
    }.get()
    print("Read \(read) transcripts in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    print("\(summary.conversations) conversations, \(summary.messages) messages, "
          + "\(ByteCountFormatter.string(fromByteCount: summary.bytesIndexed, countStyle: .file)) of transcripts.")
}

func cmdSearch(_ args: Args) throws {
    let query = args.positional.joined(separator: " ")
    guard !query.isEmpty else { fail("search needs some words") }
    let limit = Int(args.values["limit"] ?? "") ?? 10
    let started = Date()
    let hits = try runBlocking { () -> Result<[HistorySearch.Hit], Error> in
        do {
            return .success(try await HistoryIndex(url: HistoryIndex.defaultURL()).search(query, options: .init(limit: limit)))
        } catch { return .failure(error) }
    }.get()
    let elapsed = Date().timeIntervalSince(started) * 1000
    for hit in hits {
        print("\(hit.title)  (\(hit.matchingMessages) messages)")
    }
    print("\(hits.count) conversations in \(Int(elapsed)) ms.")
}

func cmdLive() {
    let sessions = LiveSessions.running()
    let word: [LiveSession.State: String] = [.working: "Working", .needsYou: "Needs you", .idle: "Idle"]
    for session in sessions {
        let place = session.isInDesktop ? "Claude" : "Terminal"
        let minutes = Int(Date().timeIntervalSince(session.since) / 60)
        print("\((word[session.state] ?? "").padding(toLength: 10, withPad: " ", startingAt: 0))"
              + "\(session.projectName.padding(toLength: 28, withPad: " ", startingAt: 0))"
              + "\(place.padding(toLength: 10, withPad: " ", startingAt: 0))for \(minutes) min")
    }
    print("\(sessions.count) running.")
}

func cmdInstalls() {
    let snapshot = runBlocking { await Catalog().snapshot() }
    let counts = Dictionary(grouping: snapshot.conversations, by: \.installID)
    for install in snapshot.installs {
        let conversations = counts[install.id] ?? []
        let missing = conversations.filter(\.isTranscriptMissing).count
        var line = "\(install.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            + "\(String(conversations.count).leftPadded(to: 5)) conversations"
        if missing > 0 { line += ", \(missing) without messages" }
        print(line)
        print("  \(HostPaths.current.abbreviating(install.dataRoot.path))")
        if let app = install.appURL { print("  \(app.path)") }
    }
}

func cmdCheckUpdate(_ args: Args) {
    let current = args.values["from"] ?? AppVersion.current
    let result = runBlocking { () -> Result<String, Error> in
        do {
            guard let update = try await Updater.check(currentVersion: current) else {
                return .success("Up to date: no release is newer than \(current).")
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("cowork-check-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let app = try await Updater.download(update, into: staging,
                                                 expectingBundleIdentifier: "com.betterclaude.app")
            return .success("\(update.version) is available, and its download verified: \(app.lastPathComponent), signed by the release key.")
        } catch {
            return .failure(error)
        }
    }
    switch result {
    case .success(let message): print(message)
    case .failure(let error): fail("\(error)")
    }
}

func cmdStorage() {
    let snapshot = runBlocking { await Catalog().snapshot() }
    var total: Int64 = 0
    var freeable: Int64 = 0
    for install in snapshot.installs {
        let cowork = snapshot.conversations.filter { $0.installID == install.id && $0.coworkSession != nil }.count
        let categories = Storage.categories(for: install, coworkConversations: cowork).map { Storage.measure($0) }
        guard !categories.isEmpty else { continue }
        print(install.name)
        for category in categories where category.bytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: category.bytes, countStyle: .file)
            let tag = category.safety == .yours ? "" : "  (can be freed)"
            print("  \(category.title.padding(toLength: 30, withPad: " ", startingAt: 0))"
                  + "\(size.leftPadded(to: 10))\(category.isApproximate ? "+" : "")\(tag)")
            total += category.bytes
            if category.safety != .yours { freeable += category.bytes }
        }
    }
    print("\nIn total \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)); "
          + "\(ByteCountFormatter.string(fromByteCount: freeable, countStyle: .file)) can be freed.")
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Runs an async operation from this synchronous command dispatcher.
///
/// The CLI is a straight-line script with no run loop, so there is nothing to suspend into;
/// blocking the main thread on a semaphore is the whole point rather than a mistake. The work
/// itself still fans out across cores inside the task.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached(priority: .userInitiated) {
        result = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

// MARK: - Commands

func cmdStores() throws {
    let stores = try Discovery.stores()
    guard !stores.isEmpty else {
        print("No Claude Desktop session stores found.")
        return
    }
    // Machine-wide: an organisation's name lives in whichever install recorded it, and the
    // same org is shared across installs.
    let orgDirectory = OrgDirectory.build(stores: stores)
    let running = (try? Guards.runningVariants()) ?? []
    for store in stores {
        var tags: [String] = []
        if store.isOrphan { tags.append("no launcher") }
        if running.contains(where: { $0.userDataDir.standardizedFileURL == store.userDataDir.standardizedFileURL }) {
            tags.append("RUNNING")
        }
        let suffix = tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"
        print("\(store.variantDirName)\(suffix)")
        print("  \(store.userDataDir.path)")
        for account in try Discovery.accounts(in: store, orgDirectory: orgDirectory) {
            print("  · \(account.displayIdentity)  ·  \(account.orgLabel)"
                  + "  \(account.sessionCount) session(s)"
                  + (account.isSignedIn ? "  [signed in]" : ""))
            print("      --account \(account.accountId) --org \(account.orgId)")
        }
    }
    if !running.isEmpty {
        print("\nRunning Claude processes (a store cannot be written to while its app runs):")
        for variant in running {
            print("  pid \(variant.pid)  →  \(variant.userDataDir.lastPathComponent)")
        }
    }
}

func resolveAccount(_ args: Args) throws -> AccountRef {
    guard let variant = args.values["store"] else { fail("--store is required") }
    let stores = try Discovery.stores()
    guard let store = stores.first(where: { $0.variantDirName == variant }) else {
        fail("no store named \(variant). Run `cowork stores` to see what is available.")
    }
    let accounts = try Discovery.accounts(in: store)
    if let accountId = args.values["account"] {
        let org = args.values["org"]
        guard let match = accounts.first(where: {
            $0.accountId == accountId && (org == nil || $0.orgId == org)
        }) else { fail("no account \(accountId) in \(variant)") }
        return match
    }
    let populated = accounts.filter { $0.sessionCount > 0 }
    if populated.count == 1 { return populated[0] }
    if accounts.count == 1 { return accounts[0] }
    fail("\(variant) has \(accounts.count) accounts; pass --account and --org (see `cowork stores`)")
}

func cmdList(_ args: Args) throws {
    if args.flags.contains("code") {
        let configDir = args.values["config"].map { URL(fileURLWithPath: $0) }
            ?? Discovery.defaultClaudeCodeConfigDir()
        let projects: [URL]
        if let project = args.values["project"] {
            projects = try PathEncoder.candidateDirectories(
                for: PathEncoder.resolvedPath(project),
                in: configDir.appendingPathComponent("projects"))
        } else {
            projects = try Discovery.claudeCodeProjects(configDir: configDir)
        }
        var total = 0
        for projectDir in projects {
            let sessions = try Discovery.claudeCodeSessions(projectDir: projectDir, configDir: configDir)
            guard !sessions.isEmpty else { continue }
            print("\(sessions[0].resolvedCwd)")
            for session in sessions.sorted(by: { $0.lastTimestamp > $1.lastTimestamp }) {
                print("  \(session.sessionId)  \(stamp.string(from: session.lastTimestamp))  "
                      + "\(session.recordCount) records  \(session.title)")
                total += 1
            }
        }
        print("\n\(total) session(s)")
        return
    }

    let account = try resolveAccount(args)
    let sessions = try Discovery.sessions(in: account)
    print("\(account.store.variantDirName) · \(account.displayIdentity)")
    for session in sessions.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
        let mark = session.transcriptURL == nil ? "  [no transcript]" : ""
        let archived = session.isArchived ? "  [archived]" : ""
        print("  \(session.sessionId)")
        print("      \(stamp.string(from: session.lastActivityAt))  \(bytes(session.byteSize))"
              + "  \(session.model)\(archived)\(mark)")
        print("      \(session.title)")
    }
    print("\n\(sessions.count) session(s)")
}

func cmdExport(_ args: Args) throws {
    guard let out = args.values["out"] else { fail("--out <file.coworkbundle> is required") }
    let ids = Set(args.positional)
    guard !ids.isEmpty else { fail("name at least one session id (see `cowork list`)") }

    let profile = RedactionProfile(rawValue: args.values["profile"] ?? "same-user")
        ?? RedactionProfile(rawValue: (args.values["profile"] ?? "").replacingOccurrences(of: "-", with: ""))
        ?? .sameUser
    var options = ExportOptions(redactionProfile: profile)
    options.includeUploads = args.flags.contains("uploads")
    options.includeOutputs = args.flags.contains("outputs")

    var coworkMatches: [SessionRef] = []
    for store in try Discovery.stores() {
        for account in try Discovery.accounts(in: store) {
            coworkMatches.append(contentsOf: try Discovery.sessions(in: account).filter {
                ids.contains($0.sessionId) || ids.contains($0.cliSessionId)
            })
        }
    }

    var ccMatches: [CCSessionRef] = []
    if coworkMatches.count < ids.count {
        let configDir = args.values["config"].map { URL(fileURLWithPath: $0) }
            ?? Discovery.defaultClaudeCodeConfigDir()
        for projectDir in (try? Discovery.claudeCodeProjects(configDir: configDir)) ?? [] {
            let sessions = (try? Discovery.claudeCodeSessions(projectDir: projectDir, configDir: configDir)) ?? []
            ccMatches.append(contentsOf: sessions.filter { ids.contains($0.sessionId) })
        }
    }

    guard !coworkMatches.isEmpty || !ccMatches.isEmpty else { fail("no session matched \(ids.joined(separator: ", "))") }

    let plan = coworkMatches.isEmpty
        ? try Exporter.plan(ccMatches, options: options)
        : try Exporter.plan(coworkMatches, options: options)
    for warning in plan.warnings { print("warning: \(warning)") }

    let url = URL(fileURLWithPath: out)
    let manifest = try Exporter.write(plan, to: url, profile: profile)
    print("Wrote \(url.lastPathComponent) — \(manifest.sessions.count) session(s), \(bytes(plan.totalBytes)) of source material")
    for entry in manifest.sessions {
        print("  \(entry.slot)  \(entry.chat.recordCount) records, \(entry.chat.userTurns) user turns  \(entry.chat.title)")
    }
}

func cmdInspect(_ args: Args) throws {
    guard let path = args.positional.first else { fail("name a bundle") }
    let url = URL(fileURLWithPath: path)
    let manifest = try BundleReader.openManifest(at: url)
    print("bundle version \(manifest.bundleVersion)   produced by \(manifest.producer)")
    print("created \(stamp.string(from: manifest.createdAt))   profile \(manifest.redactionProfile.rawValue)")
    for entry in manifest.sessions {
        print("\n\(entry.slot)  \(entry.chat.title)")
        print("  origin       \(entry.origin.kind)\(entry.origin.variantDirName.map { " · \($0)" } ?? "")")
        print("  chat         \(entry.chat.recordCount) records, \(entry.chat.userTurns) user / "
              + "\(entry.chat.assistantTurns) assistant turns")
        print("  media        \(entry.chat.inlineMediaBlocks) block(s), \(bytes(Int64(entry.chat.inlineMediaBytes)))")
        print("  chain        \(entry.chat.orphanParentUuids) orphan(s)")
        print("  files        \(entry.files.count)")
    }
    if let scan = try BundleReader.openScanReport(at: url) {
        print("\nscan: \(scan.status.rawValue) — \(scan.filesScanned) files, \(bytes(Int64(scan.bytesScanned)))")
        for finding in scan.findings {
            print("  \(finding.tier)  \(finding.ruleId)  ×\(finding.count)  \(finding.path)")
        }
    }
    let problems = try BundleReader.verify(at: url)
    print(problems.isEmpty ? "\nintegrity: all checksums match"
                           : "\nintegrity: \(problems.count) problem(s)\n  " + problems.joined(separator: "\n  "))
}

func parseEndpoint(_ spec: String, args: Args) throws -> Endpoint {
    if spec.hasPrefix("code:") {
        let path = String(spec.dropFirst(5))
        let configDir = args.values["config"].map { URL(fileURLWithPath: $0) }
            ?? Discovery.defaultClaudeCodeConfigDir()
        return .claudeCode(projectDir: URL(fileURLWithPath: path), configDir: configDir)
    }
    guard spec.hasPrefix("cowork:") else { fail("--to must start with cowork: or code:") }
    let parts = String(spec.dropFirst(7)).split(separator: "/").map(String.init)
    guard let variant = parts.first else { fail("--to cowork:<variant>[/<account>/<org>]") }
    var probe = Args([])
    probe.values["store"] = variant
    if parts.count >= 3 {
        probe.values["account"] = parts[1]
        probe.values["org"] = parts[2]
    }
    return .cowork(try resolveAccount(probe))
}

func cmdImport(_ args: Args) throws {
    guard let path = args.positional.first else { fail("name a bundle") }
    guard let to = args.values["to"] else { fail("--to is required") }
    let endpoint = try parseEndpoint(to, args: args)

    var options = ImportOptions()
    options.quitRunningVariant = args.flags.contains("quit-running")
    options.minimalMetadata = args.flags.contains("minimal")
    options.regenerateCliSessionId = args.flags.contains("new-ids")
    options.allowEmptyAccount = args.flags.contains("force-account")

    let plan = try Importer.plan(bundle: URL(fileURLWithPath: path), to: endpoint, options: options)

    print("Import \(plan.manifest.sessions.count) session(s) → \(endpoint.describedDestination)")
    print("Direction: \(plan.direction.rawValue)\n")
    print("Preconditions:")
    for check in plan.preconditions {
        let mark = check.passed ? "ok  " : "FAIL"
        print("  \(mark) [\(check.id)] \(check.title)" + (check.detail.map { "\n         \($0)" } ?? ""))
    }
    print("\nWould create:")
    for url in plan.willCreate { print("  \(url.path)") }
    if !plan.willModify.isEmpty {
        print("\nWould modify:")
        for url in plan.willModify { print("  \(url.path)") }
    }
    for computation in plan.computed {
        print("\n\(computation.slot)  \(computation.title)")
        if let id = computation.newSessionId { print("  session      \(id)") }
        print("  transcript   \(computation.cliSessionId).jsonl")
        print("  cwd          \(computation.newCwd)")
        print("  project dir  \(computation.encodedProjectDir)")
    }

    if args.flags.contains("dry-run") {
        print("\n--dry-run: nothing written.")
        return
    }
    guard plan.isExecutable else {
        fail("preconditions not met:\n  " + plan.failures.joined(separator: "\n  "))
    }

    let receipt = try Importer.apply(plan, options: options) { message in print("  \(message)") }
    print("\nImported. Receipt \(receipt.id) (\(receipt.created.count) path(s) created)")
    switch endpoint {
    case .cowork:
        print("Open Claude to see the session. It appears in the list for the signed-in account.")
    case .claudeCode(let projectDir, _):
        print("Run `claude --resume` from \(projectDir.path) — accept the one-time trust prompt if asked.")
    }
    print("Undo with: cowork undo \(receipt.id)")
}

func cmdReceipts() throws {
    let receipts = try Undo.receipts()
    guard !receipts.isEmpty else { print("No imports recorded."); return }
    for receipt in receipts.sorted(by: { $0.timestamp > $1.timestamp }) {
        let state = receipt.completed ? "" : "  [INCOMPLETE — an import was interrupted]"
        print("\(receipt.id)  \(stamp.string(from: receipt.timestamp))  \(receipt.direction.rawValue)\(state)")
        print("  → \(receipt.destination)   \(receipt.created.count) path(s)")
    }
}

func cmdUndo(_ args: Args) throws {
    guard let id = args.positional.first else { fail("name a receipt id (see `cowork receipts`)") }
    guard let receipt = try Undo.receipts().first(where: { $0.id == id }) else { fail("no receipt \(id)") }
    let result = try Undo.revert(receipt)
    for path in result.deleted { print("removed  \(path)") }
    for path in result.restored { print("restored \(path)") }
    for skip in result.skipped { print("kept     \(skip.path) — \(skip.reason)") }
    print(result.isClean ? "Reverted cleanly." : "Reverted, with \(result.skipped.count) path(s) left in place.")
}

func cmdLibrary(_ args: Args) throws {
    let sources = ArtifactHarvest.machineSources()
    let summary = runBlocking {
        await ArtifactHarvest.harvest(sources: sources,
                                      maximumConcurrency: ProcessInfo.processInfo.activeProcessorCount)
    }
    var shown = summary.artifacts
    if let kind = args.values["kind"], let k = ArtifactKind(rawValue: kind) {
        shown = shown.filter { $0.kind == k }
    }
    let limit = args.values["limit"].flatMap(Int.init) ?? 25
    let megabytes = Double(summary.totalBytes) / 1_048_576
    print("\(summary.artifacts.count) artifacts · \(String(format: "%.1f", megabytes)) MB · "
          + "\(summary.duplicatesCollapsed) duplicates collapsed · "
          + "\(summary.conversationsScanned) conversations\n")
    for artifact in shown.prefix(limit) {
        let lines = artifact.lineCount.map { "\($0)L" } ?? "—"
        print("  \(artifact.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) "
              + "\(artifact.title.prefix(46).padding(toLength: 46, withPad: " ", startingAt: 0)) "
              + "\(lines.padding(toLength: 6, withPad: " ", startingAt: 0)) "
              + "from: \(artifact.conversationTitle.prefix(34))")
    }
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
let args = Args(Array(argv.dropFirst()))

do {
    switch command {
    case "installs": cmdInstalls()
    case "storage": cmdStorage()
    case "check-update": cmdCheckUpdate(args)
    case "stores": try cmdStores()
    case "list": try cmdList(args)
    case "export": try cmdExport(args)
    case "inspect": try cmdInspect(args)
    case "import": try cmdImport(args)
    case "receipts": try cmdReceipts()
    case "undo": try cmdUndo(args)
    case "library": try cmdLibrary(args)
    case "index": try cmdIndex(args)
    case "live": cmdLive()
    case "search": try cmdSearch(args)
    case "encode":
        guard let path = args.positional.first else { fail("name a path") }
        print(PathEncoder.encode(resolving: path))
    case "-h", "--help", "help": print(usage)
    default: fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
