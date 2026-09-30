import AppKit
import CoworkKit
import SwiftUI
import UniformTypeIdentifiers

/// A month with Claude on one card, to look back on or save as an image.
@MainActor
@Observable
final class MonthModel: Identifiable {
    nonisolated let id = "month"
    var month: Date
    private(set) var stats: MonthStats?
    var showsNames = false

    init(month: Date = Date()) { self.month = month }

    func load(index: HistoryIndex?) {
        guard let index else { return }
        let month = month
        Task {
            let built = try? await MonthStats.build(index: index, month: month)
            if built?.month == Calendar.current.dateInterval(of: .month, for: self.month)?.start { stats = built }
        }
    }

    func step(_ months: Int, index: HistoryIndex?) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
        month = next
        stats = nil
        load(index: index)
    }

    var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }
}

struct MonthSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: MonthModel
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Button { model.step(-1, index: services.index.index) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.secondary)
                    .help("The month before")
                Button { model.step(1, index: services.index.index) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.secondary)
                    .disabled(model.isCurrentMonth)
                    .help("The month after")
                Spacer()
                Toggle("Show project names", isOn: $model.showsNames)
                    .toggleStyle(.checkbox)
            }

            Group {
                if let stats = model.stats {
                    MonthCard(stats: stats, showsNames: model.showsNames)
                } else {
                    ProgressView().frame(width: 640, height: 560)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button("Done") { onClose() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy Image") { copyImage() }
                    .buttonStyle(.secondary)
                    .disabled(model.stats == nil)
                Button("Save Image…") { saveImage() }
                    .buttonStyle(.primary)
                    .disabled(model.stats == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 720)
        .onAppear { model.load(index: services.index.index) }
    }

    private func image() -> NSImage? {
        guard let stats = model.stats else { return nil }
        let renderer = ImageRenderer(content: MonthCard(stats: stats, showsNames: model.showsNames)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copyImage() {
        guard let image = image() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
    }

    private func saveImage() {
        guard let image = image(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.month.formatted(.dateTime.month(.wide).year())) with Claude.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url, options: .atomic)
    }
}

/// The card itself: drawn the same on screen and in the saved image.
struct MonthCard: View {
    let stats: MonthStats
    let showsNames: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(stats.month.formatted(.dateTime.month(.wide))) with Claude")
                    .font(.system(size: 30, weight: .bold))
                Text("Every Claude on this Mac, \(stats.month.formatted(.dateTime.month(.wide).year()))")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 0) {
                big("\(stats.conversations)", "conversations")
                big("\(stats.prompts)", "prompts")
                big("\(stats.activeDays)", "days active")
                big("\(stats.longestStreak)", stats.longestStreak == 1 ? "day in a row" : "days in a row")
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Each day").font(Theme.Font.caption).foregroundStyle(.secondary)
                    calendar
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(stats.busiestHour.map { "Each hour, busiest at \(hourName($0))" } ?? "Each hour")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    hoursChart
                }
            }

            HStack(alignment: .top, spacing: 28) {
                if !stats.models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Models").font(Theme.Font.caption).foregroundStyle(.secondary)
                        let total = max(1, stats.models.reduce(0) { $0 + $1.replies })
                        ForEach(stats.models.prefix(4), id: \.name) { model in
                            HStack(spacing: 8) {
                                Text(model.name).font(Theme.Font.callout).frame(width: 90, alignment: .leading)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.accent.opacity(0.8))
                                    .frame(width: max(4, 90 * CGFloat(model.replies) / CGFloat(total)), height: 10)
                                Text("\(Int((100 * Double(model.replies) / Double(total)).rounded()))%")
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .fixedSize()
                        }
                    }
                }
                if !stats.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tools Claude used most").font(Theme.Font.caption).foregroundStyle(.secondary)
                        ForEach(stats.tools.prefix(5), id: \.name) { tool in
                            HStack {
                                Text(tool.name).font(Theme.Font.callout).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(tool.uses.formatted()).font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(width: 180)
                        }
                    }
                }
                if !stats.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Projects").font(Theme.Font.caption).foregroundStyle(.secondary)
                        if showsNames {
                            ForEach(stats.projects, id: \.name) { project in
                                Text(project.name).font(Theme.Font.callout).lineLimit(1)
                            }
                        } else {
                            Text("\(stats.projects.count) projects").font(Theme.Font.callout)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 28) {
                fact(stats.cost.formatted(.currency(code: "USD").precision(.fractionLength(0))), "at list prices")
                fact(tokens(stats.tokens), "tokens read and written")
                fact("\(stats.filesChanged)", stats.filesChanged == 1 ? "file changed" : "files changed")
                if stats.pullRequests > 0 { fact("\(stats.pullRequests)", stats.pullRequests == 1 ? "pull request" : "pull requests") }
                if stats.compactions > 0 { fact("\(stats.compactions)", stats.compactions == 1 ? "compaction" : "compactions") }
            }

            HStack(spacing: 6) {
                ForkMark(size: 13)
                Text("Better Claude").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 640, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text(label).font(Theme.Font.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.Font.headline).monospacedDigit()
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private var calendar: some View {
        let calendar = Calendar.current
        // Monday first: blanks before the first day.
        let weekday = (calendar.component(.weekday, from: stats.month) + 5) % 7
        let cells: [Int?] = Array(repeating: nil, count: weekday) + stats.days.map { Optional($0) }
        let peak = max(1, stats.days.max() ?? 1)
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        if let count = rows[row][column] {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(count == 0 ? Theme.subtleFill : Theme.accent.opacity(0.25 + 0.75 * Double(count) / Double(peak)))
                                .frame(width: 18, height: 18)
                        } else {
                            Color.clear.frame(width: 18, height: 18)
                        }
                    }
                }
            }
        }
    }

    private var hoursChart: some View {
        let peak = max(1, stats.hours.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stats.hours[hour] == 0 ? Theme.subtleFill : Theme.accent.opacity(0.85))
                        .frame(width: 9, height: max(3, 96 * CGFloat(stats.hours[hour]) / CGFloat(peak)))
                }
            }
            .frame(height: 96, alignment: .bottom)
            HStack {
                Text("Midnight"); Spacer(); Text("Noon"); Spacer(); Text("11 PM")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .frame(width: 24 * 12)
        }
    }

    private func hourName(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        return Calendar.current.date(from: components)?.formatted(.dateTime.hour()) ?? "\(hour):00"
    }

    private func tokens(_ count: Int64) -> String {
        count >= 1_000_000_000 ? "\((Double(count) / 1e9).formatted(.number.precision(.fractionLength(1))))B"
            : count >= 1_000_000 ? "\((Double(count) / 1e6).formatted(.number.precision(.fractionLength(0))))M"
            : count >= 1_000 ? "\(count / 1_000)K" : "\(count)"
    }
}
