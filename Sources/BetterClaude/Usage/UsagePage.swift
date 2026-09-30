import Charts
import CoworkKit
import SwiftUI

/// Every account's plan limits, where the week is heading, and what used it.
struct UsagePage: View {
    @Environment(AppServices.self) private var services
    @AppStorage(PulseNotifier.limitsKey) private var notifyLimits = true

    var body: some View {
        let usage = services.usage
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage").font(Theme.Font.display)
                        Text("Your plan limits in every account, where this week is heading, and what used it.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Your Month…") { services.lookingBack = MonthModel() }
                        .buttonStyle(.secondary)
                        .help("A month with Claude on one card, to look back on or save as an image")
                }
                .padding(.bottom, Theme.Space.xl)

                if usage.loaded && usage.quotas.isEmpty {
                    DetailSection(title: "No readings yet") {
                        Text("Claude records how much of your limits you've used while it's open. Once Claude or Claude Code has been used on this Mac, your limits show up here.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                WeekSection()
                ModelDriftSection()
                ForEach(usage.quotas) { quota in
                    AccountUsageSection(quota: quota, items: usage.spend[quota.account.id] ?? [])
                }
                if !usage.quotas.isEmpty {
                    DetailSection(title: "Alerts") {
                        ExplainedToggle(title: "Before you hit a limit",
                                        detail: "A notification when an account passes 80% and 95% of its five-hour or weekly limit, once each time, naming the account with the most room left.",
                                        isOn: $notifyLimits)
                    }
                    Text("The percentages are Claude's own. Which projects and conversations used them is estimated from the tokens each reply used, weighed at API list prices, since plan limits aren't published as a formula.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.l)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { usage.refresh(snapshot: services.snapshot, index: services.index.index) }
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
                    if let window = quota.window(.fiveHour) { LimitMeter(window: window) }
                    if let window = quota.window(.weekly) { LimitMeter(window: window) }
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
            return ("At this week's pace, you'll reach the weekly limit \(Self.when(date)).", true)
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
        let high = window.percent >= 80
        VStack(alignment: .leading, spacing: 6) {
            Text(window.kind.title).font(Theme.Font.callout).foregroundStyle(.secondary)
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
                    Capsule().fill(high ? Theme.attention : Theme.accent)
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
