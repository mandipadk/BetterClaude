import AppKit
import CoworkKit
import SwiftUI

/// On an install's page: what's failing around its Claude Code sessions this week.
struct HealthSection: View {
    @Environment(AppServices.self) private var services
    let install: Install
    @State private var issues: [Doctor.Issue] = []

    var body: some View {
        // A real container: a task on an empty Group never runs.
        VStack(alignment: .leading, spacing: 0) {
            let drift = services.formats.breaking(for: install)
            if !issues.isEmpty || drift != nil {
                DetailSection(title: "Needs attention",
                              subtitle: "What went wrong around this Claude's Code sessions in the last week, as Claude Code recorded it.") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if let drift { driftRow(drift) }
                        ForEach(issues) { issue in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                                Image(systemName: symbol(issue.kind)).foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(issue)).font(Theme.Font.body)
                                    Text(detail(issue)).font(Theme.Font.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: services.index.generation) {
            services.formats.check(services.snapshot.conversations)
            guard let index = services.index.index else { return }
            issues = (try? await Doctor.issues(index: index, installIDs: [install.id],
                                               since: Date().addingTimeInterval(-7 * 86_400))) ?? []
        }
    }

    /// This install's tool now writes its files in a way Better Claude doesn't fully read.
    private func driftRow(_ report: FormatSurvey.Report) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.contract.name) \(report.shape.version) changed how it records \(report.affected)")
                    .font(Theme.Font.body)
                Text("Better Claude may miss this in newer conversations until it's updated. The report lists field names only, never what was said.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Copy Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.shareable, forType: .string)
            }
            .buttonStyle(.secondary)
        }
    }

    private func symbol(_ kind: TranscriptScan.HealthEvent.Kind) -> String {
        switch kind {
        case .mcpFailed: return "exclamationmark.triangle"
        case .mcpNeedsAuth: return "person.badge.key"
        case .hookFailed: return "bolt.trianglebadge.exclamationmark"
        }
    }

    private func title(_ issue: Doctor.Issue) -> String {
        switch issue.kind {
        case .mcpFailed: return "\(issue.name) didn't start"
        case .mcpNeedsAuth: return "\(issue.name) needs you to sign in"
        case .hookFailed: return "The \(issue.name) hook failed"
        }
    }

    private func detail(_ issue: Doctor.Issue) -> String {
        var parts: [String] = []
        if issue.kind == .mcpFailed, let code = issue.detail { parts.append(explain(code)) }
        if issue.kind == .hookFailed, let detail = issue.detail { parts.append(detail.prefix(1).uppercased() + detail.dropFirst() + ".") }
        if issue.kind == .mcpNeedsAuth { parts.append("Its tools aren't available until you do, from /mcp in Claude Code.") }
        let when = issue.lastSeen.map { "Last seen \($0.listStamp.lowercasedIfWordLocal)" } ?? ""
        parts.append(issue.sessions == 1 ? "\(when)." : "\(when), in \(issue.sessions) sessions this week.")
        return parts.joined(separator: " ")
    }

    private func explain(_ code: String) -> String {
        switch code {
        case "ECONNREFUSED": return "Nothing was listening where it's configured to connect."
        case "ENDPOINT_NOT_FOUND": return "Its address didn't answer as an MCP server."
        case "ENOENT": return "The command it starts wasn't found."
        default: return "The error was \(code)."
        }
    }
}

/// On Claude Code's page: commands Claude runs most that the settings don't allow yet.
struct CommandRulesSection: View {
    @Environment(AppServices.self) private var services
    let configDir: URL
    @State private var suggestions: [PermissionTuner.Suggestion] = []
    @State private var added: [String] = []
    @State private var failure: String?

    var body: some View {
        // A real container: a task on an empty Group never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty || !added.isEmpty {
                DetailSection(title: "Commands you could allow",
                              subtitle: "What Claude ran most in the last month that your settings still ask about. Each rule lets that command run with any arguments; nothing that deletes, publishes or reaches another machine is suggested.") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(suggestions.prefix(12)) { suggestion in
                            HStack(alignment: .center, spacing: Theme.Space.m) {
                                Text(suggestion.command)
                                    .font(Theme.Font.code)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.subtleFill, in: .rect(cornerRadius: 5))
                                Text("\(suggestion.runs) runs in \(suggestion.conversations) conversations")
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Allow") { allow([suggestion.rule]) }.buttonStyle(.secondary)
                            }
                        }
                        if !added.isEmpty {
                            HStack {
                                Text(added.count == 1 ? "1 rule added by Better Claude." : "\(added.count) rules added by Better Claude.")
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Take Them Out") { removeAdded() }.buttonStyle(.secondary)
                            }
                        }
                        if let failure {
                            Text(failure).font(Theme.Font.callout).foregroundStyle(Theme.failure)
                        }
                    }
                }
            }
        }
        .task(id: services.index.generation) { await reload() }
    }

    private func reload() async {
        added = PermissionTuner.added(configDir: configDir, paths: services.snapshot.paths)
        guard let index = services.index.index else { return }
        suggestions = (try? await PermissionTuner.suggestions(index: index, configDir: configDir,
                                                              since: Date().addingTimeInterval(-30 * 86_400))) ?? []
    }

    private func allow(_ rules: [String]) {
        do {
            try PermissionTuner.allow(rules, configDir: configDir, paths: services.snapshot.paths)
            failure = nil
        } catch {
            failure = "Couldn't change Claude Code's settings: \(error.localizedDescription)"
        }
        Task { await reload() }
    }

    private func removeAdded() {
        do {
            try PermissionTuner.removeAdded(configDir: configDir, paths: services.snapshot.paths)
        } catch {
            failure = "Couldn't change Claude Code's settings: \(error.localizedDescription)"
        }
        Task { await reload() }
    }
}

/// On the Usage page: the work in the period it shows, and a summary of it written on this Mac.
struct WeekSection: View {
    @Environment(AppServices.self) private var services
    let period: UsagePeriod
    let quotas: [AccountQuota]
    @State private var digest: WeekDigest?
    @State private var summary = ""
    @State private var summarizing = false

    var body: some View {
        // A real container: a task on an empty Group never runs.
        VStack(alignment: .leading, spacing: 0) {
            if let digest, digest.conversations > 0 {
                DetailSection(title: title,
                              subtitle: [Self.count(digest.conversations, "conversation"), Self.count(digest.prompts, "prompt"),
                                         Self.count(digest.filesChanged, "file") + " changed",
                                         Self.count(digest.commands, "command") + " run"].joined(separator: ", ") + ".") {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if !digest.projects.isEmpty {
                            ForEach(digest.projects, id: \.name) { project in
                                ShareRow(title: project.name,
                                         detail: project.conversations == 1 ? "1 conversation" : "\(project.conversations) conversations",
                                         share: Double(project.conversations) / Double(max(1, digest.conversations)))
                            }
                        }
                        if !summary.isEmpty {
                            MarkdownView(summary)
                                .padding(Theme.Space.l)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
                        }
                        if services.ask.availability == .available {
                            HStack {
                                if summarizing { ProgressView().controlSize(.small) }
                                Button(summary.isEmpty ? (period == .month ? "Summarize My Month" : "Summarize My Week")
                                                       : "Summarize Again") { summarize(digest) }
                                    .buttonStyle(.secondary)
                                    .disabled(summarizing)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(period.rawValue)#\(services.index.generation)#\(quotas.map(\.account.id))") {
            guard let index = services.index.index else { return }
            // The same accounts over the same stretch as the rest of the page; with no limits
            // read yet, every account by the calendar.
            var spans = period.spans(for: quotas).map {
                WeekDigest.Span(accountIDs: $0.accountIDs, since: $0.since, until: $0.until)
            }
            if spans.isEmpty {
                let stretch = period.calendarSpan()
                spans = [WeekDigest.Span(accountIDs: nil, since: stretch.since, until: stretch.until)]
            }
            let built = try? await WeekDigest.build(index: index, spans: spans)
            if built != digest { summary = "" }
            digest = built
        }
    }

    private var title: String {
        switch period {
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .month: return "This month"
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func summarize(_ digest: WeekDigest) {
        summarizing = true
        Task {
            summary = await OnDeviceModel.write(instructions: WeekDigest.instructions, prompt: digest.prompt) { partial in
                summary = partial
            } ?? summary
            summarizing = false
        }
    }
}
