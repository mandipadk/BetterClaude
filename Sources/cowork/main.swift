import CoworkKit
import Foundation

// Argument parsing is hand-rolled rather than pulling in swift-argument-parser: the package
// otherwise has no external dependencies, which keeps the app buildable offline.

let usage = """
cowork — move Claude Cowork sessions between Claude Desktop installs and Claude Code

USAGE
  cowork check [--reader]
      --reader: for every conversation, whether the reader shows every compaction, recap and
      prompt the transcript holds (counts only).
      Check every count against the disk: what each Claude lists, what was found but left
      out and why, and anything that doesn't add up.

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

  cowork port --project <name> [--store <variant>] [--folder <path>] [--code-tab <install>] [--dry-run]
      Move a Cowork project into Claude Code: every conversation resumable in its folder, its
      files in From Cowork/, a CLAUDE.md, and a brief for a new project. The tasks stay as they are.

  cowork export --project <name> [--store <variant>] --out <file.coworkbundle>
      Export every conversation in a Cowork project, which carries the project with it.

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

  cowork file <path>
      Where a file came from: the conversations that changed it, every version Claude Code
      saved, and the commits that changed it with the conversation each likely came from.

  cowork distill
      Prompts you repeat, commands Claude runs that your settings don't allow yet, what's
      failing around Claude Code's turns, and this week in numbers.

  cowork formats [--all] [--write <dir>]
      Check that Better Claude still understands what this Mac's Claude Code and Codex write.
      --all surveys every conversation, not just the latest; --write merges each version's
      shape (fields and kinds of record, never content) into <dir>/<tool>/<version>.json.

  cowork projects
      Every project folder Claude worked in, with its conversations, cost and last activity.

  cowork month [YYYY-MM]
      A month with every Claude in numbers: conversations, prompts, active days, models,
      tools and cost.

  cowork corrections [--counts]
      Corrections you've made in two or more conversations of a project, worded as lines
      for its CLAUDE.md. --counts prints only how many per project.

  cowork claims
      How many things Claude and its sub-agents said they did are backed by their
      transcripts, contradicted by them, or have nothing to back them.

  cowork secrets [--counts]
      Find API keys and tokens that ended up in a conversation, masked, with where each
      appears. --counts prints only how many of each kind.

  cowork usage
      Show each account's five-hour and weekly limits, when they reset, where the week is
      heading, and which projects used the most this week.

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
    let rebuild = args.flags.contains("rebuild")
    let started = Date()
    let (read, summary) = try runBlocking { () -> Result<(Int, HistoryIndex.Summary), Error> in
        do {
            let index = try HistoryIndex(url: url)
            // Emptied rather than deleted: the app may have it open.
            if rebuild { try await index.reset() }
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
            return .success(try await HistoryIndex(readingFrom: HistoryIndex.defaultURL()).search(query, options: .init(limit: limit)))
        } catch { return .failure(error) }
    }.get()
    let elapsed = Date().timeIntervalSince(started) * 1000
    for hit in hits {
        print("\(hit.title)  (\(hit.matchingMessages) messages)")
    }
    print("\(hits.count) conversations in \(Int(elapsed)) ms.")
}

func cmdFile(_ args: Args) throws {
    guard let raw = args.positional.first else { fail("name a file") }
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    let (history, commits) = try runBlocking { () -> Result<(FileHistory, [CommitLink]), Error> in
        do {
            let index = try HistoryIndex(readingFrom: HistoryIndex.defaultURL())
            return .success((try await FileProvenance.history(of: path, index: index),
                             try await CommitLinker.commits(touching: path, index: index)))
        } catch { return .failure(error) }
    }.get()
    print(path)
    if history.createdByClaude { print("Created by Claude.") }
    print("\n\(history.conversations.count) conversation\(history.conversations.count == 1 ? "" : "s") touched it:")
    for touch in history.conversations {
        print("  \(touch.title)  (\(touch.tools.joined(separator: ", ")))")
    }
    print("\n\(history.versions.count) saved version\(history.versions.count == 1 ? "" : "s"):")
    for version in history.versions {
        let state = version.didNotExist ? "didn't exist" : version.copy == nil ? "copy gone" : "restorable"
        print("  v\(version.version)  \(version.savedAt.map { stamp.string(from: $0) } ?? "")  \(state)  before a change in \(version.conversationTitle)")
    }
    print("\n\(commits.count) commit\(commits.count == 1 ? "" : "s"):")
    for commit in commits {
        let from = commit.match.map { "\($0.confidence.rawValue) from \($0.title)" } ?? "no conversation found"
        print("  \(commit.shortSHA)  \(commit.subject)  (\(from))")
    }
}

func cmdDistill() throws {
    let paths = HostPaths.current
    let prompts = PromptLibrary.repeated(configDirs: LiveSessions.configDirs(paths: paths))
    let (suggestions, issues, digest) = try runBlocking { () -> Result<([PermissionTuner.Suggestion], [Doctor.Issue], WeekDigest), Error> in
        do {
            let index = try HistoryIndex(readingFrom: HistoryIndex.defaultURL())
            let snapshot = await Catalog().snapshot()
            let week = Date().addingTimeInterval(-7 * 86_400)
            let codeInstalls = Set(snapshot.installs.filter { $0.kind == .claudeCode || $0.isDesktop }.map(\.id))
            return .success((try await PermissionTuner.suggestions(index: index, configDir: paths.claudeCodeConfigDir,
                                                                   since: Date().addingTimeInterval(-30 * 86_400)),
                             try await Doctor.issues(index: index, installIDs: codeInstalls, since: week),
                             try await WeekDigest.build(index: index, since: week)))
        } catch { return .failure(error) }
    }.get()
    print("\(prompts.count) prompts you've typed three times or more.")
    for prompt in prompts.prefix(5) {
        print("  \(prompt.uses) times  \(String(prompt.text.replacingOccurrences(of: "\n", with: " ").prefix(70)))")
    }
    print("\n\(suggestions.count) commands Claude runs that your settings don't allow yet:")
    for suggestion in suggestions.prefix(10) { print("  \(suggestion.rule)  \(suggestion.runs) runs in \(suggestion.conversations) conversations") }
    print("\n\(issues.count) things failing this week:")
    for issue in issues.prefix(10) { print("  \(issue.kind.rawValue)  \(issue.name)  in \(issue.sessions) session\(issue.sessions == 1 ? "" : "s")  \(issue.detail ?? "")") }
    print("\nThis week: \(digest.conversations) conversations, \(digest.prompts) prompts, \(digest.filesChanged) files changed, \(digest.commands) commands.")
}

func cmdFormats(_ args: Args) throws {
    let all = args.flags.contains("all")
    let writeDir = args.values["write"]
    let snapshot = runBlocking { await Catalog().snapshot() }
    guard all || writeDir != nil else {
        let reports = FormatSurvey.check(snapshot.conversations)
        for report in reports {
            print("\(report.contract.name) \(report.shape.version): \(report.shape.kinds.count) kinds of record")
            if report.findings.isEmpty { print("  Everything Better Claude reads is where it expects.") }
            for finding in report.findings { print("  \(finding.breaksSomething ? "Breaks" : "New")  \(finding)") }
        }
        return
    }
    for contract in [FormatContract.claudeCode, FormatContract.codex] {
        let urls = snapshot.conversations.compactMap { conversation -> URL? in
            if let external = conversation.external { return external.source == .codex && contract.format == "codex" ? external.fileURL : nil }
            return contract.format == "claude-code" ? conversation.transcriptURL : nil
        }
        let shapes = FormatSurvey.shapes(of: urls, contract: contract)
        print("\(contract.name): \(shapes.count) versions in \(urls.count) conversations")
        for version in FormatSurvey.ordered(shapes.keys) {
            guard var shape = shapes[version] else { continue }
            if let writeDir {
                let folder = URL(fileURLWithPath: writeDir).appendingPathComponent(contract.format)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(version).json")
                if let data = try? Data(contentsOf: file), let existing = try? FormatShape.decode(data) { shape.merge(existing) }
                try shape.encoded().write(to: file, options: .atomic)
            }
            let findings = contract.check(shape)
            print("  \(version)  \(shape.kinds.count) kinds\(findings.isEmpty ? "" : "  " + findings.map(\.description).joined(separator: "; "))")
        }
    }
}

func cmdCorrections(_ args: Args) throws {
    let suggestions = try runBlocking { () -> Result<[CorrectionSuggestion], Error> in
        do { return .success(try await Corrections.suggestions(index: try HistoryIndex(readingFrom: HistoryIndex.defaultURL()))) }
        catch { return .failure(error) }
    }.get()
    print("\(suggestions.count) corrections you keep making.")
    let byProject = Dictionary(grouping: suggestions) { $0.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "every project" }
    for (project, items) in byProject.sorted(by: { $0.value.count > $1.value.count }) {
        if args.flags.contains("counts") {
            print("  \(items.count) in a project, from \(items.map(\.examples.count).reduce(0, +)) corrections")
        } else {
            print("\n\(project)")
            for item in items { print("  \(item.rule)  (\(item.examples.count) times in \(item.conversations) conversations)") }
        }
    }
}

func cmdClaims() throws {
    let counts = try runBlocking { () -> Result<[String: Int], Error> in
        do {
            let index = try HistoryIndex(readingFrom: HistoryIndex.defaultURL())
            var counts: [String: Int] = [:]
            for row in try await index.rows("SELECT id FROM conversations WHERE kind != 'claudeWeb'") {
                guard let id = row.text(0) else { continue }
                for claim in try await Claims.check(conversationID: id, index: index) {
                    let verdict: String
                    switch claim.verdict {
                    case .backed: verdict = "backed"
                    case .contradicted: verdict = "contradicted"
                    case .noEvidence: verdict = "nothing to back it"
                    case .unclear: verdict = "couldn't check"
                    }
                    counts["\(claim.agentID == nil ? "Claude" : "sub-agents"), \(claim.kind.rawValue): \(verdict)", default: 0] += 1
                }
            }
            return .success(counts)
        } catch { return .failure(error) }
    }.get()
    for (key, count) in counts.sorted(by: { $0.key < $1.key }) { print("\(count)  \(key)") }
}

func cmdProjects() throws {
    let projects = try runBlocking { () -> Result<[ProjectSummary], Error> in
        do { return .success(try await Projects.list(index: try HistoryIndex(readingFrom: HistoryIndex.defaultURL()))) }
        catch { return .failure(error) }
    }.get()
    print("\(projects.count) projects.")
    for project in projects {
        let cost = project.cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        print("  \(project.name)  \(project.conversations) conversations  \(cost)  \(project.filesChanged) files  \(project.places.joined(separator: ", "))")
    }
}

func cmdMonth(_ args: Args) throws {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM"
    let month = args.positional.first.flatMap(formatter.date(from:)) ?? Date()
    let stats = try runBlocking { () -> Result<MonthStats, Error> in
        do { return .success(try await MonthStats.build(index: try HistoryIndex(readingFrom: HistoryIndex.defaultURL()), month: month)) }
        catch { return .failure(error) }
    }.get()
    print("\(stats.month.formatted(.dateTime.month(.wide).year())): \(stats.conversations) conversations, \(stats.prompts) prompts, \(stats.replies) replies.")
    print("  \(stats.activeDays) days active, \(stats.longestStreak) in a row, busiest hour \(stats.busiestHour.map(String.init) ?? "none").")
    print("  Models: " + stats.models.map { "\($0.name) \($0.replies)" }.joined(separator: ", "))
    print("  Tools: " + stats.tools.map { "\($0.name) \($0.uses)" }.joined(separator: ", "))
    print("  \(stats.cost.formatted(.currency(code: "USD").precision(.fractionLength(0)))) at list prices, \(stats.tokens) tokens, \(stats.filesChanged) files, \(stats.pullRequests) pull requests, \(stats.compactions) compactions.")
}

func cmdSecrets(_ args: Args) {
    let snapshot = runBlocking { await Catalog().snapshot() }
    let files = SecretSweep.files(in: snapshot)
    let started = Date()
    let findings = SecretSweep.sweep(files)
    let handled = HandledSecrets.load()
    let open = findings.filter { !handled.contains($0.fingerprint) }
    print("\(open.count) keys in \(Set(open.flatMap(\.conversations)).count) conversations (\(files.count) read in \(String(format: "%.1f", Date().timeIntervalSince(started)))s).")
    if args.flags.contains("counts") {
        for (name, group) in Dictionary(grouping: open, by: \.kind.name).sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(group.count)")
        }
        return
    }
    let titles = Dictionary(snapshot.conversations.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    for finding in open {
        print("\n\(finding.kind.name)  \(finding.masked)")
        for sighting in finding.sightings.prefix(5) {
            print("  \(sighting.source.description): \(titles[sighting.conversationID] ?? sighting.conversationID)")
        }
    }
}

func cmdUsage() throws {
    let (quotas, spend) = try runBlocking { () -> Result<([AccountQuota], [String: [(name: String, cost: Double, conversations: Int)]]), Error> in
        do {
            let snapshot = await Catalog().snapshot()
            let quotas = QuotaReader.accounts(in: snapshot)
            let index = try? HistoryIndex(readingFrom: HistoryIndex.defaultURL())
            var spend: [String: [(name: String, cost: Double, conversations: Int)]] = [:]
            for quota in quotas {
                guard let index else { break }
                let since = quota.weekStart ?? Date().addingTimeInterval(-7 * 86_400)
                let items = try await QuotaAttribution.items(index: index, accountIDs: [quota.account.id], since: since)
                spend[quota.account.id] = QuotaAttribution.byProject(items)
            }
            return .success((quotas, spend))
        } catch { return .failure(error) }
    }.get()
    let when = DateFormatter()
    when.dateFormat = "EEE HH:mm"
    for quota in quotas {
        print(quota.account.displayName)
        for window in quota.windows {
            var line = "  \(window.title): \(Int(window.percent.rounded()))%"
            if let reset = window.resetsAt {
                line += ", resets \(window.resetIsEstimate ? "about " : "")\(when.string(from: reset))"
            }
            print(line)
        }
        switch quota.forecast {
        case .reachesLimit(let date)?: print("  At this pace the weekly limit runs out \(when.string(from: date)).")
        case .leftAtReset(let left)?: print("  At this pace \(Int(left.rounded()))% is left when it resets.")
        case nil: break
        }
        let projects = spend[quota.account.id] ?? []
        let total = projects.reduce(0) { $0 + $1.cost }
        for project in projects.prefix(5) where total > 0 {
            print("  \(Int((project.cost / total * 100).rounded()))%  \(project.name) (\(project.conversations) conversation\(project.conversations == 1 ? "" : "s"))")
        }
        print("  \(quota.history.count) readings, the latest \(Int(Date().timeIntervalSince(quota.asOf) / 60)) min ago\n")
    }
    if let summary = try? runBlocking({ () -> Result<CacheBreaks.Summary, Error> in
        do { return .success(try await CacheBreaks.summary(index: try HistoryIndex(readingFrom: HistoryIndex.defaultURL()),
                                                           since: Date().addingTimeInterval(-30 * 86_400))) }
        catch { return .failure(error) }
    }).get(), summary.breaks > 0 {
        let extra = summary.extra.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        print("Coming back after a break, the last 30 days: \(summary.breaks) replies re-read their conversation after the cache expired, \(summary.tokens / 1_000_000)M tokens, about \(extra) more at list prices than reading them from the cache.")
    }
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

func cmdCheckReader() {
    let snapshot = runBlocking { await Catalog().snapshot() }
    var total = ReaderCheck.Result()
    var incomplete = 0, read = 0, unexplained = 0
    for conversation in snapshot.conversations where conversation.external == nil {
        guard let url = conversation.transcriptURL, let transcript = try? Transcript(contentsOf: url) else { continue }
        let result = ReaderCheck.check(transcript)
        read += 1
        total = total + result
        if !result.isComplete { incomplete += 1 }
        // Prompts missing where nothing was rewound can't be on a rewound attempt.
        if result.promptsShown < result.prompts, result.rewound == 0 { unexplained += 1 }
        if result.compactionsShown < result.compactions || result.recapsShown < result.recaps { unexplained += 1 }
    }
    print("Read \(read) conversations.")
    print("  Compactions: \(total.compactionsShown) shown of \(total.compactions)")
    print("  Recaps: \(total.recapsShown) shown of \(total.recaps)")
    print("  Prompts: \(total.promptsShown) shown of \(total.prompts)")
    print("  Rewound attempts folded into a line: \(total.rewound) (prompts in them aren't shown on their own)")
    if incomplete == 0 {
        print("The reader shows everything.")
    } else {
        print("\(incomplete) conversations show less than their transcript holds; \(unexplained) of them can't be explained by a rewound attempt.")
    }
}

func cmdCheck() {
    let report = runBlocking { () -> AccuracyCheck.Report in
        let snapshot = await Catalog().snapshot()
        let index = try? HistoryIndex(readingFrom: HistoryIndex.defaultURL())
        return await AccuracyCheck.run(snapshot: snapshot, index: index)
    }
    for source in report.sources {
        var line = "\(source.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(String(source.listed).leftPadded(to: 5)) listed"
        if source.archived > 0 { line += ", \(source.archived) archived" }
        if source.withoutMessages > 0 { line += ", \(source.withoutMessages) without messages" }
        print(line)
        for item in source.leftOut { print("  not listed: \(item)") }
    }
    print("\(report.total) conversations listed.")
    if report.issues.isEmpty { print("Everything adds up."); return }
    for issue in report.issues { print("- \(issue.title): \(issue.count). \(issue.detail)") }
}

func cmdInstalls() {
    let snapshot = runBlocking { await Catalog().snapshot() }
    let counts = Dictionary(grouping: snapshot.conversations, by: \.installID)
    for install in snapshot.installs {
        // Counted the way the app's sidebar counts: archived ones apart.
        let all = counts[install.id] ?? []
        let conversations = all.filter { !$0.isArchived }
        let archived = all.count - conversations.count
        let missing = conversations.filter(\.isTranscriptMissing).count
        var line = "\(install.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            + "\(String(conversations.count).leftPadded(to: 5)) conversations"
        if archived > 0 { line += ", \(archived) archived" }
        if missing > 0 { line += ", \(missing) without messages" }
        print(line)
        print("  \(HostPaths.current.abbreviating(install.dataRoot.path))")
        if let app = install.appURL { print("  \(app.path)") }
        if install.kind == .external(.codex) {
            let survey = CodexSessions.survey()
            var left: [String] = []
            if let n = survey.counts[.subagent] { left.append("\(n) sub-agent threads") }
            if let n = survey.counts[.review] { left.append("\(n) automatic reviews") }
            for (program, n) in survey.automatedBy.sorted(by: { $0.value > $1.value }) { left.append("\(n) runs by \(program)") }
            if !left.isEmpty { print("  Not listed: " + left.joined(separator: ", ")) }
        }
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
        if running.contains(where: { $0.userDataDir.resolvingSymlinksInPath().path == store.userDataDir.resolvingSymlinksInPath().path }) {
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
            let owner = stores.first { $0.userDataDir.resolvingSymlinksInPath().path == variant.userDataDir.resolvingSymlinksInPath().path }
            print("  pid \(variant.pid)  →  \(owner?.variantDirName ?? variant.userDataDir.lastPathComponent)")
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

func cmdPort(_ args: Args) throws {
    guard let name = args.values["project"] else { fail("--project <name> is required") }
    var sessions: [SessionRef] = []
    for store in try Discovery.stores() where args.values["store"].map({ $0 == store.variantDirName }) ?? true {
        for account in try Discovery.accounts(in: store) { sessions += try Discovery.sessions(in: account) }
    }
    let matches = CoworkProjects.projects(in: sessions).filter { $0.name == name }
    guard let project = matches.first else { fail("no Cowork project named \(name) holds a conversation") }
    if matches.count > 1 { fail("more than one Cowork project is named \(name); pick one with --store") }

    let folderPath = args.values["folder"].map { ($0 as NSString).expandingTildeInPath } ?? project.space.folders.first
    guard let folderPath else { fail("the project has no folder; pass --folder <path>") }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("\(folderPath) isn't a folder on this Mac")
    }
    var codeTabRoot: URL?
    if let installName = args.values["code-tab"] {
        guard let install = InstallDiscovery.all().first(where: { $0.name == installName }),
              let root = install.codeTabRoot else { fail("no Claude named \(installName) has a Code tab") }
        codeTabRoot = root
    }

    let index = try? HistoryIndex(readingFrom: HistoryIndex.defaultURL())
    let conversations = runBlocking { await CoworkPort.conversations(project.sessions, index: index) }
    let staging = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cowork-port-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let plan = try CoworkPort.plan(name: project.name, space: project.space, conversations: conversations,
                                   folder: URL(fileURLWithPath: folderPath), codeTabRoot: codeTabRoot, staging: staging)
    print("\(project.name): \(project.sessions.count) conversation(s) from \(project.account.store.variantDirName) into \(folderPath)")
    for check in plan.importPlan.preconditions where !check.passed || check.isNotice {
        print("  \(check.passed ? "note" : "FAIL") [\(check.id)] \(check.title)\(check.detail.map { ": \($0)" } ?? "")")
    }
    print("  CLAUDE.md: \(plan.claudeMD == nil ? "already there, left alone" : "will be written")")
    print("  Briefs: \(conversations.filter { $0.brief != nil }.count) of \(conversations.count) from the history index")
    print("  Code tab: \(plan.codeTab.map { _ in args.values["code-tab"] ?? "" } ?? "not listed")")
    guard plan.isExecutable else { fail("nothing was written") }
    if args.flags.contains("dry-run") { print("--dry-run: nothing written."); return }

    let receipt = try CoworkPort.apply(plan) { print("  \($0)") }
    print("Moved. Receipt \(receipt.id) (\(receipt.created.count) path(s) created)")
    print("Resume with `claude --resume` in \(folderPath). Undo with: cowork undo \(receipt.id)")
}

func cmdExport(_ args: Args) throws {
    guard let out = args.values["out"] else { fail("--out <file.coworkbundle> is required") }
    var ids = Set(args.positional)
    if let name = args.values["project"] {
        var sessions: [SessionRef] = []
        for store in try Discovery.stores() where args.values["store"].map({ $0 == store.variantDirName }) ?? true {
            for account in try Discovery.accounts(in: store) { sessions += try Discovery.sessions(in: account) }
        }
        let matches = CoworkProjects.projects(in: sessions).filter { $0.name == name }
        guard let project = matches.first else { fail("no Cowork project named \(name) holds a conversation") }
        if matches.count > 1 { fail("more than one Cowork project is named \(name); pick one with --store") }
        print("\(project.name): \(project.sessions.count) conversation(s) in \(project.account.store.variantDirName)")
        ids.formUnion(project.sessions.map(\.sessionId))
    }
    guard !ids.isEmpty else { fail("name at least one session id (see `cowork list`), or --project <name>") }

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
    if receipt.revertedAt != nil { fail("receipt \(id) has already been undone") }
    let result = try Undo.revertAndRecord(receipt)
    for path in result.deleted { print("removed  \(path)") }
    for path in result.restored { print("restored \(path)") }
    for skip in result.skipped { print("kept     \(skip.path) — \(skip.reason)") }
    let left = result.leftInPlace.count
    print(left == 0 ? "Reverted cleanly."
          : result.canRetry ? "Reverted, with \(left) path(s) left in place. Run undo again to retry."
          : "Reverted, with \(left) changed path(s) kept.")
}

func cmdLibrary(_ args: Args) throws {
    let summary = runBlocking { () -> HarvestSummary in
        let sources = ArtifactHarvest.sources(in: await Catalog().snapshot())
        return await ArtifactHarvest.harvest(sources: sources,
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
    case "check": args.flags.contains("reader") ? cmdCheckReader() : cmdCheck()
    case "storage": cmdStorage()
    case "check-update": cmdCheckUpdate(args)
    case "stores": try cmdStores()
    case "list": try cmdList(args)
    case "export": try cmdExport(args)
    case "port": try cmdPort(args)
    case "inspect": try cmdInspect(args)
    case "import": try cmdImport(args)
    case "receipts": try cmdReceipts()
    case "undo": try cmdUndo(args)
    case "library": try cmdLibrary(args)
    case "index": try cmdIndex(args)
    case "live": cmdLive()
    case "usage": try cmdUsage()
    case "distill": try cmdDistill()
    case "formats": try cmdFormats(args)
    case "secrets": cmdSecrets(args)
    case "projects": try cmdProjects()
    case "claims": try cmdClaims()
    case "corrections": try cmdCorrections(args)
    case "month": try cmdMonth(args)
    case "file": try cmdFile(args)
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
