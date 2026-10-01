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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Home", subtitle: summary)
                TipView(PaletteTip())
                    .tipBackground(Theme.groupFill)
                    .padding(.top, Theme.Space.l)
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        left.frame(maxWidth: .infinity, alignment: .top)
                        right.frame(width: 340, alignment: .top)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) { left; right }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Two columns once there's room for both to breathe.
        .onGeometryChange(for: Bool.self) { $0.size.width > 820 } action: { wide = $0 }
        .task(id: services.index.isReady) {
            if services.index.isReady { services.home.refresh(services) }
        }
    }

    // MARK: Columns

    @ViewBuilder
    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            let waiting = services.pulse.needingYou
            if !waiting.isEmpty {
                GroupLabel(title: "Needs you")
                RowGroup {
                    ForEach(waiting) { session in
                        LiveSessionRow(session: session, compact: true).padding(.horizontal, 14)
                    }
                }
            }
            let now = services.pulse.sessions.filter { $0.state != .needsYou }
            GroupLabel(title: "Now", link: "Running", action: { services.destination = .running })
            RowGroup {
                if now.isEmpty {
                    GroupRow(title: "Nothing running", detail: "Claude Code sessions show up here while they work.") { EmptyView() }
                } else {
                    ForEach(now.prefix(5)) { session in
                        LiveSessionRow(session: session, compact: true).padding(.horizontal, 14)
                    }
                }
            }
            let insights = services.home.shown(services)
            if !insights.isEmpty {
                GroupLabel(title: "Worth a look")
                RowGroup {
                    ForEach(insights) { insight in
                        GroupRow(title: insight.title, detail: insight.detail) {
                            HStack(spacing: Theme.Space.s) {
                                Button("Not Now") { services.home.notNow(insight) }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                Button(insight.action) { services.home.open(insight, services) }
                                    .buttonStyle(.bordered)
                            }
                            .fixedSize()
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
                GroupLabel(title: "Limits", link: "Usage", action: { services.destination = .usage })
                RowGroup {
                    ForEach(quotas) { quota in
                        LimitRow(quota: quota)
                    }
                }
            }
            GroupLabel(title: "Pick up where you left off", link: "All", action: {
                services.filter = .all
                services.destination = .conversations
            })
            RowGroup(inset: 46) {
                ForEach(recent) { conversation in
                    Button { services.show(conversation) } label: {
                        GroupRow(title: conversation.title, detail: recentDetail(conversation)) {
                            if let install = services.install(for: conversation) {
                                InstallIcon(install: install, size: 20)
                            }
                        } trailing: { RowChevron() }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ConversationActions(conversation: conversation, asContextMenu: true) }
                }
            }
        }
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
        let tight = services.usage.quotas.first { quota in
            if case .reachesLimit? = quota.forecast { return true }
            return false
        }
        if let tight, case .reachesLimit(let date)? = tight.forecast {
            parts.append("\(tight.account.displayName) reaches its weekly limit \(AccountUsageSection.when(date)) at this pace")
        } else if !services.usage.quotas.isEmpty {
            parts.append(services.usage.quotas.count == 1 ? "your account has room this week" : "every account has room this week")
        }
        guard !parts.isEmpty else { return "Nothing is waiting for you." }
        var sentence = parts.joined(separator: ", ")
        if parts.count > 1, let last = parts.last {
            sentence = parts.dropLast().joined(separator: ", ") + " and " + last
        }
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }
}

/// An account's weekly limit: the figure, a meter with where this week is heading, and what
/// that means in words.
struct LimitRow: View {
    let quota: AccountQuota

    var body: some View {
        let weekly = quota.window(.weekly)?.percent ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.account.displayName).font(Theme.Font.bodyMedium).lineLimit(1)
                Spacer()
                Text("\(Text("\(Int(weekly.rounded()))").font(Theme.Font.figure))\(Text("%").font(Theme.Font.callout).foregroundStyle(.secondary))")
                    .contentTransition(.numericText())
            }
            Meter(value: weekly / 100, mark: forecastMark)
            Text(sentence)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
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
        case .leftAtReset(let left)?: return "This week. About \(Int(left.rounded()))% left when it resets."
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
