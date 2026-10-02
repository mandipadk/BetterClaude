import Charts
import CoworkKit
import SwiftUI

/// Every account's plan limits, where the week is heading, and what used it: the answer
/// first, then the evidence.
struct UsagePage: View {
    @Environment(AppServices.self) private var services
    @State private var period: UsagePeriod = .thisWeek
    @State private var data = UsageData()

    var body: some View {
        let usage = services.usage
        PageScroll {
            PageTitle(title: "Usage", subtitle: headline(usage.quotas))
            if usage.loaded && usage.quotas.isEmpty {
                SectionLabel(title: "No readings yet")
                Card {
                    Row(title: "Claude records your limits while it's open",
                        detail: "Once Claude or Claude Code has been used on this Mac, every account's limits show up here.")
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .top), GridItem(.flexible(), spacing: 24, alignment: .top)],
                      alignment: .leading, spacing: 0) {
                ForEach(usage.quotas) { quota in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(title: quota.account.displayName, detail: places(quota))
                        Card {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .top),
                                                GridItem(.flexible(), spacing: 24, alignment: .top)],
                                      alignment: .leading, spacing: 16) {
                                ForEach(quota.windows, id: \.title) { window in
                                    half(Self.label(for: window), window: window, quota: quota)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }
                }
            }
            // The three below cover the same stretch of time; it's said once, above them.
            if let period = data.period {
                Text(period)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Surface.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 26)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 3),
                      alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "What used it", top: data.period == nil ? 26 : 10)
                    Card {
                        let total = data.projects.reduce(0) { $0 + $1.cost }
                        if data.projects.isEmpty { Row(title: "Nothing yet", detail: period.emptyLine) }
                        ForEach(data.projects.prefix(5), id: \.name) { project in
                            let share = total > 0 ? project.cost / total : 0
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(project.name).font(.system(size: 13)).foregroundStyle(Theme.Surface.primary).lineLimit(1)
                                    Spacer()
                                    RowValue(text: "\(Int((share * 100).rounded()))%")
                                }
                                ThinMeter(value: share)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "Coming back after a break", top: data.period == nil ? 26 : 10)
                    Card {
                        if let breaks = data.breaks, breaks.breaks > 0 {
                            Row(title: "\(breaks.breaks) repl\(breaks.breaks == 1 ? "y" : "ies") rewrote an expired cache",
                                detail: breaks.projects.first.map { "Mostly \($0.name)" }) {
                                RowValue(text: Self.dollars(breaks.extra))
                            }
                            if let longest = breaks.longest {
                                Row(title: "Longest break", detail: title(of: longest.conversationID)) {
                                    RowValue(text: MarkerLine.duration(longest.gap))
                                }
                            }
                        } else {
                            Row(title: "No expired caches", detail: "Every reply read the conversation from the cache.")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "Models", top: data.period == nil ? 26 : 10)
                    Card {
                        let total = data.models.reduce(0) { $0 + $1.cost }
                        if data.models.isEmpty { Row(title: "Nothing yet", detail: period.emptyLine) }
                        ForEach(data.models.prefix(4), id: \.name) { model in
                            Row(title: humanModelName(model.name),
                                detail: data.drifted.contains(model.name) ? "Switched to on its own" : nil,
                                detailColor: Theme.attention) {
                                RowValue(text: total > 0 ? "\(Int((model.cost / total * 100).rounded()))%" : "")
                            }
                        }
                    }
                }
            }
            if !data.heaviest.isEmpty {
                SectionLabel(title: "Heaviest conversations")
                Card {
                    let total = data.heaviest.reduce(0) { $0 + $1.cost }
                    ForEach(data.heaviest.prefix(5)) { item in
                        Button {
                            if let conversation = services.snapshot.conversations.first(where: { $0.id == item.conversationID }) {
                                services.show(conversation)
                            }
                        } label: {
                            Row(title: item.title, detail: item.place) {
                                RowValue(text: Self.dollars(item.cost))
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        .help(total > 0 ? "\(Int((item.cost / total * 100).rounded()))% of the period" : "")
                    }
                }
            }
            WeekSection(period: period, quotas: usage.quotas)
            Text("Percentages are Claude's own. What used them is estimated from each reply's tokens at API list prices, since plan limits aren't published as a formula.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Surface.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Segmented(options: UsagePeriod.allCases.map { ($0, $0.title) }, selection: $period)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button("Your Month") { services.lookingBack = MonthModel() }
                    .help("A month with Claude on one card, to look back on or save as an image")
            }
            ToolbarItem(placement: .primaryAction) {
                SearchPill(prompt: "Search", width: 150) { services.showsPalette = true }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear { usage.refresh(snapshot: services.snapshot, index: services.index.index) }
        .task(id: "\(period.rawValue)#\(services.index.generation)#\(usage.quotas.count)") {
            guard let index = services.index.index else { return }
            data = await UsageData.load(index: index, period: period, quotas: usage.quotas)
        }
    }

    private func half(_ label: String, window: QuotaWindow, quota: AccountQuota) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
            Figure(value: "\(Int(window.percent.rounded()))", unit: "%").padding(.top, 4)
            ThinMeter(value: window.percent / 100, mark: window == quota.tightestWeekly ? forecastMark(quota) : nil)
                .padding(.top, 7).padding(.bottom, 6)
            Text(note(window, quota: quota)).font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ window: QuotaWindow, quota: AccountQuota) -> String {
        if window.isStale { return "No reading in the last five hours" }
        if window == quota.tightestWeekly, let forecast = quota.forecast {
            switch forecast {
            case .reachesLimit(let date): return "Full by \(date.formatted(.dateTime.weekday(.wide).hour()))"
            case .leftAtReset(let left): return "Heading for \(Int((100 - left).rounded()))% by \((window.resetsAt ?? .now).formatted(.dateTime.weekday(.wide)))"
            }
        }
        guard let reset = window.resetsAt else { return "Resets within five hours" }
        return "Resets \(Calendar.current.isDateInToday(reset) ? reset.formatted(date: .omitted, time: .shortened) : reset.formatted(.dateTime.weekday(.wide).hour().minute()))"
    }

    private func forecastMark(_ quota: AccountQuota) -> Double? {
        switch quota.forecast {
        case .leftAtReset(let left)?: return max(0, min(1, (100 - left) / 100))
        case .reachesLimit?: return 1
        case nil: return nil
        }
    }

    private func places(_ quota: AccountQuota) -> String? {
        let names = quota.installIDs.compactMap { services.install($0)?.name }
        return names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
    }

    private func title(of conversationID: String) -> String {
        services.snapshot.conversations.first { $0.id == conversationID }?.title ?? "A conversation"
    }

    static func dollars(_ value: Double) -> String { Pricing.dollars(value) }

    /// What a limit's half of an account card is called: "Five hours", "This week", "Fable this week".
    static func label(for window: QuotaWindow) -> String {
        switch window.kind {
        case .fiveHour: return "Five hours"
        case .weekly: return "This week"
        default: return "\(window.scope ?? "One model") this week"
        }
    }

    /// "weekly limit", or "weekly limit for Fable" for one that covers a single model.
    static func limitName(_ window: QuotaWindow?) -> String {
        guard let window, window.kind != .weekly, window.kind != .fiveHour else { return "weekly limit" }
        return window.title.prefix(1).lowercased() + window.title.dropFirst()
    }

    /// The answer first: where the tightest account is heading.
    private func headline(_ quotas: [AccountQuota]) -> String {
        for quota in quotas {
            if case .reachesLimit(let date)? = quota.forecast {
                return "At this pace, \(quota.account.displayName) reaches its \(Self.limitName(quota.tightestWeekly)) \(AccountUsageSection.when(date))."
            }
        }
        if quotas.isEmpty { return "Your plan limits in every account, where this week is heading, and what used it." }
        return quotas.count == 1 ? "Your account has room this week." : "Every account has room this week."
    }
}

enum UsagePeriod: String, CaseIterable, Hashable {
    case thisWeek, lastWeek, month

    var title: String {
        switch self {
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .month: return Date().formatted(.dateTime.month(.wide))
        }
    }

    var emptyLine: String {
        switch self {
        case .thisWeek: return "Nothing has used your limits this week."
        case .lastWeek: return "Nothing used your limits last week."
        case .month: return "Nothing has used your limits this month."
        }
    }

    /// A stretch of time and the accounts read over it.
    struct Span: Equatable {
        var accountIDs: Set<String>
        let since: Date
        let until: Date
        /// The account's plan week, from its last reset, rather than the calendar's.
        let planWeek: Bool
    }

    /// The stretch by the calendar: this week, last week, or this month.
    func calendarSpan(now: Date = Date(), calendar: Calendar = .current) -> (since: Date, until: Date) {
        let calendarWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86_400)
        switch self {
        case .thisWeek: return (calendarWeek, .distantFuture)
        case .lastWeek: return (calendar.date(byAdding: .weekOfYear, value: -1, to: calendarWeek) ?? calendarWeek, calendarWeek)
        case .month: return (calendar.dateInterval(of: .month, for: now)?.start ?? calendarWeek, .distantFuture)
        }
    }

    /// A week is each account's plan week, as its limits count it, where Claude has said when
    /// that began, and the calendar week otherwise. Accounts on the same stretch share a span.
    func spans(for quotas: [AccountQuota], now: Date = Date(), calendar: Calendar = .current) -> [Span] {
        let byCalendar = calendarSpan(now: now, calendar: calendar)
        var spans: [Span] = []
        for quota in quotas {
            let id: Set<String> = [quota.account.id]
            let span: Span
            switch self {
            case .thisWeek:
                span = Span(accountIDs: id, since: quota.weekStart ?? byCalendar.since, until: .distantFuture,
                            planWeek: quota.weekStart != nil)
            case .lastWeek:
                // A plan week resets at the same instant each week; a calendar week starts at
                // midnight, which a clock change can put 23 or 25 hours from the last.
                if let start = quota.weekStart {
                    span = Span(accountIDs: id, since: start.addingTimeInterval(-7 * 86_400), until: start, planWeek: true)
                } else {
                    span = Span(accountIDs: id, since: byCalendar.since, until: byCalendar.until, planWeek: false)
                }
            case .month:
                span = Span(accountIDs: id, since: byCalendar.since, until: byCalendar.until, planWeek: false)
            }
            if let same = spans.firstIndex(where: { $0.since == span.since && $0.until == span.until }) {
                spans[same].accountIDs.formUnion(id)
            } else {
                spans.append(span)
            }
        }
        return spans
    }

    /// Says what the stretch is: a plan week starts whenever the account's limit last reset.
    func describe(_ spans: [Span]) -> String? {
        guard let first = spans.first, self != .month else { return nil }
        if spans.count > 1 { return self == .thisWeek ? "Each account's own week" : "Each account's week before this one" }
        let day = Date.FormatStyle().month(.abbreviated).day()
        switch self {
        case .thisWeek:
            return first.planWeek ? "Plan week, since \(first.since.formatted(.dateTime.weekday(.wide).hour()))"
                                  : "Since \(first.since.formatted(.dateTime.weekday(.wide)))"
        default:
            // A calendar week ends at midnight, which reads as the day before.
            let end = first.planWeek ? first.until : first.until.addingTimeInterval(-1)
            let range = "\(first.since.formatted(day)) to \(end.formatted(day))"
            return first.planWeek ? "Plan week, \(range)" : range
        }
    }
}

/// What Usage shows for a stretch of time, read from the index: every section covers the
/// same accounts over the same stretch.
struct UsageData {
    var period: String?
    var projects: [(name: String, cost: Double, conversations: Int)] = []
    var heaviest: [QuotaAttribution.Item] = []
    var breaks: CacheBreaks.Summary?
    var models: [(name: String, cost: Double)] = []
    var drifted: Set<String> = []

    static func load(index: HistoryIndex, period: UsagePeriod, quotas: [AccountQuota]) async -> UsageData {
        let spans = period.spans(for: quotas)
        var data = UsageData()
        data.period = period.describe(spans)
        var items: [QuotaAttribution.Item] = []
        var models: [String: Double] = [:]
        var breaks: [CacheBreaks.Summary] = []
        for span in spans {
            items += (try? await QuotaAttribution.items(index: index, accountIDs: span.accountIDs,
                                                        since: span.since, until: span.until)) ?? []
            for model in (try? await QuotaAttribution.models(index: index, accountIDs: span.accountIDs,
                                                             since: span.since, until: span.until)) ?? [] {
                models[model.name, default: 0] += model.cost
            }
            if let summary = try? await CacheBreaks.summary(index: index, accountIDs: span.accountIDs,
                                                            since: span.since, until: span.until) {
                breaks.append(summary)
            }
            if let drift = try? await ModelDrift.unexplained(index: index, accountIDs: span.accountIDs,
                                                             since: span.since, until: span.until) {
                data.drifted.formUnion(drift.map(\.change.to))
            }
        }
        data.heaviest = items.sorted { $0.cost > $1.cost }
        data.projects = QuotaAttribution.byProject(items)
        data.breaks = breaks.isEmpty ? nil : CacheBreaks.Summary.combined(breaks)
        data.models = models.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        return data
    }
}

struct AccountUsageSection: View {
    @Environment(AppServices.self) private var services
    let quota: AccountQuota
    let items: [QuotaAttribution.Item]

    var body: some View {
        DetailSection(title: quota.account.displayName, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack(alignment: .top, spacing: Theme.Space.xxl) {
                    ForEach(quota.windows, id: \.title) { window in LimitMeter(window: window) }
                }
                if let forecast = forecastText {
                    Text(forecast.text)
                        .font(Theme.Font.body.weight(forecast.urgent ? .semibold : .regular))
                        .foregroundStyle(forecast.urgent ? Theme.attention : .primary)
                }
                if quota.weekStart != nil, weekHistory.count > 2 { weekChart }
                if !items.isEmpty { spendList }
                Text("Read \(quota.asOf.formatted(.relative(presentation: .named)))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let names = quota.installIDs.compactMap { services.install($0)?.name }
        guard !names.isEmpty else { return "Not signed in to any Claude on this Mac right now" }
        return "Signed in to " + ListFormatter.localizedString(byJoining: names)
    }

    private var forecastText: (text: String, urgent: Bool)? {
        switch quota.forecast {
        case .reachesLimit(let date)?:
            return ("At this week's pace, you'll reach the \(UsagePage.limitName(quota.tightestWeekly)) \(Self.when(date)).", true)
        case .leftAtReset(let left)?:
            return ("At this week's pace, about \(Int(left.rounded()))% will be left when it resets.", false)
        case nil:
            return nil
        }
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "today around \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow around \(time)" }
        return "\(date.formatted(.dateTime.weekday(.wide))) around \(time)"
    }

    private var weekHistory: [QuotaSample] {
        guard let start = quota.weekStart else { return [] }
        return quota.history.filter { $0.date >= start }
    }

    private var weekChart: some View {
        Chart {
            ForEach(weekHistory, id: \.date) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Weekly", sample.weekly))
                    .foregroundStyle(Theme.accent.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value("Weekly", sample.weekly))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: (quota.weekStart ?? .now)...(quota.window(.weekly)?.resetsAt ?? .now))
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(Theme.Font.caption) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Weekly limit used over this week")
    }

    private var spendList: some View {
        let total = items.reduce(0) { $0 + $1.cost }
        let projects = QuotaAttribution.byProject(items)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("What used it this week").font(Theme.Font.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(projects.prefix(5), id: \.name) { project in
                    ShareRow(title: project.name,
                             detail: project.conversations == 1 ? "1 conversation" : "\(project.conversations) conversations",
                             share: total > 0 ? project.cost / total : 0)
                }
            }
            Text("Heaviest conversations").font(Theme.Font.callout).foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(4)) { item in
                    Button {
                        if let conversation = services.snapshot.conversations.first(where: { $0.id == item.conversationID }) {
                            services.show(conversation)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(Theme.Font.body).lineLimit(1)
                            Spacer(minLength: Theme.Space.m)
                            Text("\(Int((total > 0 ? item.cost / total * 100 : 0).rounded()))%")
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One limit: how much is used, as a big number and a bar, and when it resets.
struct LimitMeter: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.title).font(Theme.Font.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(window.percent.rounded()))%")
                    .font(Theme.Font.hero)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("used").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.subtleFill)
                    Capsule().fill(Theme.accentBright)
                        .frame(width: max(4, geometry.size.width * min(1, window.percent / 100)))
                }
            }
            .frame(height: 6)
            Text(resetText)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        if window.isStale { return "No reading in the last five hours" }
        guard let reset = window.resetsAt else {
            return window.kind == .fiveHour ? "Resets within five hours of your first message" : "Reset time not known yet"
        }
        let about = window.resetIsEstimate ? "about " : ""
        if reset.timeIntervalSinceNow < 12 * 3_600 {
            let minutes = max(1, Int(reset.timeIntervalSinceNow / 60))
            return minutes < 60 ? "Resets in \(about)\(minutes) min" : "Resets in \(about)\(minutes / 60) h \(minutes % 60) min"
        }
        return "Resets \(about)\(reset.formatted(.dateTime.weekday(.wide))) at \(reset.formatted(.dateTime.hour().minute()))"
    }
}

/// A name, a short detail, and its share as a bar and a percentage.
struct ShareRow: View {
    let title: String
    let detail: String
    let share: Double

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Font.bodyMedium).lineLimit(1)
                Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.subtleFill)
                    Capsule().fill(Theme.accent).frame(width: max(3, geometry.size.width * share))
                }
            }
            .frame(height: 5)
            Text("\(Int((share * 100).rounded()))%")
                .font(Theme.Font.callout)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
