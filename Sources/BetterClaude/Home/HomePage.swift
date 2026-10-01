import CoworkKit
import SwiftUI
import TipKit

/// What the features found, for Home's "Worth a look". The quick ones are read live; the ones
/// that read the index are worked out off the main actor and kept until the next refresh.
@MainActor
@Observable
final class HomeModel {
    private var computed: [Insight] = []
    private(set) var computing = false
    /// Which group in Memory the memory insight is about, and which conversation drifted.
    private(set) var memoryGroupID: String?
    private(set) var driftConversationID: String?
    private var snoozed: [String: Date] = HomeModel.loadSnoozed()
    private var task: Task<Void, Never>?

    static let snoozedKey = "insightsSnoozed"

    func shown(_ services: AppServices) -> [Insight] {
        let live = [Insights.secrets(open: services.secrets.open.count), Insights.month()].compactMap { $0 }
        return Insights.ranked(computed + live, snoozed: snoozed)
    }

    func refresh(_ services: AppServices) {
        guard let index = services.index.index else { return }
        if services.secrets.swept == nil, !services.secrets.sweeping { services.secrets.sweep(services.snapshot) }
        if !services.memory.loaded { services.memory.load(services.snapshot) }
        let folders = services.memory.groups.compactMap { group -> (String, URL)? in
            group.files.first { $0.name == "MEMORY.md" }.map { (group.id, $0.url.deletingLastPathComponent()) }
        }
        task?.cancel()
        computing = true
        task = Task {
            let week = Date().addingTimeInterval(-7 * 86_400)
            let found = await Task.detached(priority: .utility) { () -> ([Insight], String?, String?) in
                var insights: [Insight] = []
                var unlinked = 0, pastCut = 0
                var memoryGroup: String?
                for (id, folder) in folders {
                    guard let health = MemoryHealth.check(folder: folder), !health.isHealthy else { continue }
                    unlinked += health.unlinked.count
                    pastCut += health.linesPastCut
                    if memoryGroup == nil { memoryGroup = id }
                }
                if let memory = Insights.memory(unlinked: unlinked, pastCut: pastCut) { insights.append(memory) }
                if let suggestions = try? await Corrections.suggestions(index: index),
                   let corrections = Insights.corrections(suggestions) {
                    insights.append(corrections)
                }
                var drifted: String?
                if let switches = try? await ModelDrift.unexplained(index: index, since: week) {
                    drifted = switches.first?.change.conversationID
                    if let drift = Insights.drift(switches.map(\.title)) { insights.append(drift) }
                }
                if let breaks = try? await CacheBreaks.summary(index: index, since: week),
                   let insight = Insights.cacheBreaks(extra: breaks.extra, breaks: breaks.breaks) {
                    insights.append(insight)
                }
                return (insights, memoryGroup, drifted)
            }.value
            guard !Task.isCancelled else { return }
            computed = found.0
            memoryGroupID = found.1
            driftConversationID = found.2
            computing = false
        }
    }

    func notNow(_ insight: Insight) {
        snoozed[insight.key] = Date().addingTimeInterval(Insights.snooze)
        snoozed = snoozed.filter { $0.value > Date() }
        UserDefaults.standard.set(snoozed.mapValues(\.timeIntervalSince1970), forKey: Self.snoozedKey)
    }

    private static func loadSnoozed() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: snoozedKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Takes you to where an insight's button says.
    func open(_ insight: Insight, _ services: AppServices) {
        switch insight.kind {
        case .secrets: services.destination = .secrets
        case .corrections: services.destination = .projects
        case .memory:
            services.destination = .memory
            if let id = memoryGroupID { services.memory.selectedID = id }
        case .drift:
            if let id = driftConversationID, let conversation = services.snapshot.conversations.first(where: { $0.id == id }) {
                services.show(conversation)
            } else {
                services.destination = .usage
            }
        case .expiring: services.destination = .kept
        case .cacheBreaks: services.destination = .usage
        case .month:
            services.destination = .usage
            services.lookingBack = MonthModel(month: Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
        }
    }
}

/// The page you land on: what needs you, what's running, your limits, what's worth a look,
/// and a way back into your work. Groups appear only when they have something in them.
struct HomePage: View {
    @Environment(AppServices.self) private var services
    @State private var wide = true
    @State private var jobs: [Unattended.Job] = []

    var body: some View {
        PageScroll {
            PageTitle(title: "Home", subtitle: summary)
            TipView(PaletteTip())
                .tipBackground(Theme.Surface.group)
                .padding(.top, 18)
            if wide {
                HStack(alignment: .top, spacing: 24) {
                    left.frame(maxWidth: .infinity, alignment: .top)
                    right.frame(width: 360, alignment: .top)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) { left; right }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > 820 } action: { wide = $0 }
        .task(id: services.index.isReady) {
            if services.index.isReady { services.home.refresh(services) }
            let dirs = services.pulse.configDirs
            let day = Date().addingTimeInterval(-86_400)
            jobs = await Task.detached { Unattended.jobs(configDirs: dirs) }.value
                .filter { ($0.updated ?? .distantPast) > day }
        }
    }

    // MARK: Columns

    @ViewBuilder
    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            let waiting = services.pulse.needingYou
            if !waiting.isEmpty {
                SectionLabel(title: "Needs you")
                Card(inset: 46) {
                    ForEach(waiting) { session in needsYouRow(session) }
                }
            }
            let now = services.pulse.sessions.filter { $0.state != .needsYou }
            let shownJobs = Array(jobs.prefix(max(0, 5 - now.count)))
            SectionLabel(title: "Now",
                         link: now.count + jobs.count > 5 ? "Show All \(now.count + jobs.count)" : nil,
                         action: { services.destination = .running })
            Card(inset: 46) {
                if now.isEmpty && shownJobs.isEmpty {
                    Row(title: "Nothing running", detail: "Claude Code sessions show up here while they work.")
                } else {
                    ForEach(now.prefix(5)) { session in nowRow(session) }
                    ForEach(shownJobs) { job in jobRow(job) }
                }
            }
            let insights = services.home.shown(services)
            if !insights.isEmpty {
                SectionLabel(title: "Worth a look")
                Card {
                    ForEach(insights) { insight in
                        Row(title: insight.title, detail: insight.detail) {
                            Button("Not Now") { services.home.notNow(insight) }.buttonStyle(.quiet)
                            Button(insight.action) { services.home.open(insight, services) }.buttonStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            let quotas = services.usage.quotas.filter { $0.window(.weekly) != nil }
            if !quotas.isEmpty {
                SectionLabel(title: "Limits", link: "Usage", action: { services.destination = .usage })
                Card {
                    ForEach(quotas) { quota in LimitRow(quota: quota) }
                }
            }
            SectionLabel(title: "Pick up where you left off", link: "All", action: {
                services.filter = .all
                services.destination = .conversations
            })
            Card(inset: 46) {
                ForEach(recent) { conversation in
                    Button { services.show(conversation) } label: {
                        Row(title: conversation.title, detail: recentDetail(conversation)) {
                            appIcon(services.install(for: conversation))
                        } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ConversationActions(conversation: conversation, asContextMenu: true) }
                }
            }
        }
    }

    // MARK: Rows

    private func appIcon(_ install: Install?) -> some View {
        Group {
            if let install { InstallIcon(install: install, size: 22) } else { Color.clear }
        }
        .frame(width: 20, height: 20)
    }

    private func sessionIcon(_ session: LiveSession) -> some View {
        Group {
            if session.isInDesktop, let claude = services.installs.first(where: \.isDesktop) {
                InstallIcon(install: claude, size: 22)
            } else if let code = services.installs.first(where: { $0.kind == .claudeCode }) {
                InstallIcon(install: code, size: 22)
            } else {
                Image(systemName: "terminal").foregroundStyle(Theme.Surface.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }

    private func sessionDetail(_ session: LiveSession) -> String {
        services.conversation(forSession: session.sessionID)?.title ?? session.cwd
    }

    private func needsYouRow(_ session: LiveSession) -> some View {
        let question = services.pulse.notes[session.sessionID]?.message.map { "“\($0)”" }
        let host = services.pulse.host(of: session)?.localizedName ?? (session.isInDesktop ? "Claude" : "Claude Code")
        return Row(title: session.name ?? session.projectName, detail: question ?? sessionDetail(session), detailLines: 2) {
            sessionIcon(session)
        } trailing: {
            TimelineView(.periodic(from: .now, by: 30)) { _ in RowValue(text: Self.minutes(since: session.since)) }
            Button("Open in \(host)") { services.pulse.show(session) }.buttonStyle(.primary)
        }
        .contextMenu { sessionMenu(session) }
    }

    private func nowRow(_ session: LiveSession) -> some View {
        Button { services.pulse.show(session) } label: {
            Row(title: session.name ?? session.projectName, detail: sessionDetail(session)) {
                sessionIcon(session)
            } trailing: {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    RowValue(text: session.state == .working
                             ? "Working, \(Self.minutes(since: session.since))"
                             : "Finished \(session.since.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { sessionMenu(session) }
    }

    private func jobRow(_ job: Unattended.Job) -> some View {
        let place = job.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let value: String
        switch job.outcome {
        case .running: value = "Working, \(Self.minutes(since: job.started ?? .now))"
        case .finished: value = "Finished \((job.updated ?? .now).formatted(date: .omitted, time: .shortened))"
        case .failed: value = "Failed"
        case .stalled: value = "Stopped"
        }
        return Row(title: job.name, detail: place.map { "Background job in \($0)" } ?? "Background job") {
            appIcon(services.installs.first { $0.kind == .claudeCode })
        } trailing: {
            RowValue(text: value, attention: job.outcome == .failed || job.outcome == .stalled)
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: LiveSession) -> some View {
        Button("Show in Its App") { services.pulse.show(session) }
        if let conversation = services.conversation(forSession: session.sessionID) {
            Button("Open Conversation") { services.show(conversation) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)]) }
    }

    static func minutes(since date: Date) -> String {
        let minutes = max(1, Int(-date.timeIntervalSinceNow / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) h" : "\(hours / 24) d"
    }

    private var recent: [ConversationRef] {
        Array(services.snapshot.conversations
            .filter { !$0.isTranscriptMissing }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(5))
    }

    private func recentDetail(_ conversation: ConversationRef) -> String {
        let place = conversation.projectName ?? services.install(for: conversation)?.name ?? "Claude"
        return "\(place), \(conversation.lastActivity.listStamp.lowercasedIfWordLocal)"
    }

    /// One sentence that answers "is everything all right?".
    private var summary: String {
        var parts: [String] = []
        let waiting = services.pulse.needingYou.count
        let working = services.pulse.sessions.filter { $0.state == .working }.count
        if waiting > 0 { parts.append(waiting == 1 ? "One session needs you" : "\(waiting) sessions need you") }
        if working > 0 { parts.append(working == 1 ? "one is working" : "\(working) are working") }
        let quotas = services.usage.quotas
        if let tight = quotas.first(where: { if case .reachesLimit? = $0.forecast { return true }; return false }),
           case .reachesLimit(let date)? = tight.forecast {
            parts.append("\(tight.account.displayName) reaches its weekly limit \(AccountUsageSection.when(date))")
        } else if !quotas.isEmpty {
            parts.append(quotas.count == 1 ? "your account has room this week" : quotas.count == 2 ? "both accounts have room this week" : "every account has room this week")
        }
        guard !parts.isEmpty else { return "Nothing is waiting for you." }
        var sentence = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + ", and " + parts.last! : parts[0]
        if parts.count == 2 { sentence = parts[0] + " and " + parts[1] }
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }
}

/// An account's weekly limit: the figure, a meter with where this week is heading, and what
/// that means in words.
struct LimitRow: View {
    let quota: AccountQuota

    var body: some View {
        let weekly = quota.window(.weekly)?.percent ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.account.displayName).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Surface.primary).lineLimit(1)
                Spacer()
                Figure(value: "\(Int(weekly.rounded()))", unit: "%")
            }
            ThinMeter(value: weekly / 100, mark: forecastMark)
                .padding(.top, 7)
                .padding(.bottom, 7)
            Text(sentence)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Surface.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var forecastMark: Double? {
        switch quota.forecast {
        case .leftAtReset(let left)?: return max(0, min(1, (100 - left) / 100))
        case .reachesLimit?: return 1
        case nil: return nil
        }
    }

    private var sentence: String {
        switch quota.forecast {
        case .reachesLimit(let date)?: return "This week. At this pace, \(AccountUsageSection.when(date))."
        case .leftAtReset(let left)?:
            if left >= 30, let reset = quota.window(.weekly)?.resetsAt {
                return "This week. Plenty left, resets \(reset.formatted(.dateTime.weekday(.wide).hour()))."
            }
            return "This week. About \(Int(left.rounded()))% left when it resets."
        case nil:
            if let reset = quota.window(.weekly)?.resetsAt {
                return "This week. Resets \(reset.formatted(.dateTime.weekday(.wide).hour().minute()))."
            }
            return "This week."
        }
    }
}

/// A thin capsule: how much is used, in the accent, and an optional tick for where it's heading.
struct Meter: View {
    let value: Double
    var mark: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtleFill)
                Capsule().fill(Theme.accentBright).frame(width: geometry.size.width * max(0, min(1, value)))
                if let mark {
                    Rectangle().fill(.secondary)
                        .frame(width: 1.5, height: 10)
                        .offset(x: geometry.size.width * mark - 0.75)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
