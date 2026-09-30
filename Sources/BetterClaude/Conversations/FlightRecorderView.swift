import Charts
import CoworkKit
import SwiftUI

/// Under a conversation's header: how full the context was at every reply, where Claude
/// compacted, and which replies cost the most.
struct FlightRecorderView: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    @AppStorage("flightRecorderOpen") private var open = false
    @State private var record: FlightRecord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let record, !record.replies.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { open.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text("Cost and context").font(Theme.Font.headline)
                        Text(summary(record))
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open { detail(record).transition(.opacity) }
            }
        }
        .task(id: "\(conversation.id)#\(services.index.generation)") {
            guard let index = services.index.index else { return }
            record = try? await FlightRecord.load(conversationID: conversation.id, index: index)
        }
    }

    private func summary(_ record: FlightRecord) -> String {
        let agents = record.agents > 0
            ? ", \(dollars(record.agentCost)) of it by \(record.agents) sub-agent\(record.agents == 1 ? "" : "s")" : ""
        return "\(dollars(record.totalCost)) at list prices over \(record.replies.count) replies\(agents). Context peaked at \(tokens(record.peakContext)) of \(tokens(record.window))."
    }

    private func detail(_ record: FlightRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context read for each reply").font(Theme.Font.caption).foregroundStyle(.secondary)
                Chart {
                    ForEach(record.replies) { reply in
                        AreaMark(x: .value("Time", reply.timestamp), y: .value("Tokens", reply.context))
                            .foregroundStyle(Theme.accent.opacity(0.14))
                            .interpolationMethod(.stepEnd)
                        LineMark(x: .value("Time", reply.timestamp), y: .value("Tokens", reply.context))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.stepEnd)
                    }
                    RuleMark(y: .value("Window", record.window))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .trailing) {
                            Text("Context window").font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    ForEach(record.compactions, id: \.self) { date in
                        RuleMark(x: .value("Compacted", date))
                            .foregroundStyle(Color.primary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Compacted").font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYScale(domain: 0...Double(record.window) * 1.08)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let tokens = value.as(Int.self) { Text(self.tokens(tokens)) } }
                    }
                }
                .frame(height: 150)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Cost of each reply").font(Theme.Font.caption).foregroundStyle(.secondary)
                Chart(record.replies) { reply in
                    BarMark(x: .value("Time", reply.timestamp), y: .value("Dollars", reply.cost), width: .fixed(3))
                        .foregroundStyle(reply.afterBreak == nil ? Theme.accent.opacity(0.7) : Theme.attention)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let amount = value.as(Double.self) { Text(dollars(amount)) } }
                    }
                }
                .frame(height: 70)
                let breaks = record.replies.filter { $0.afterBreak != nil }
                if !breaks.isEmpty {
                    Text("\(breaks.count == 1 ? "One reply" : "\(breaks.count) replies") in orange came after a break long enough for the cache to expire, and wrote the conversation back into it.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Most expensive replies").font(Theme.Font.caption).foregroundStyle(.secondary)
                ForEach(record.expensive) { reply in
                    HStack(spacing: Theme.Space.l) {
                        Text(reply.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .frame(width: 120, alignment: .leading)
                        Text(dollars(reply.cost)).frame(width: 70, alignment: .trailing)
                        Text("read \(tokens(reply.context)) tokens, wrote \(tokens(reply.output))\(reply.afterBreak.map { ", after \(breakLength($0)) away" } ?? "")")
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.Font.callout)
                    .monospacedDigit()
                }
                if record.replies.count >= 20 {
                    Text("The most expensive tenth of replies cost \(Int((record.topTenthShare * 100).rounded()))% of the total. A reply costs more the more it has to read, so starting fresh or compacting sooner is what brings long conversations down.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
    }

    private func breakLength(_ gap: TimeInterval) -> String {
        gap >= 86_400 ? "\(Int(gap / 86_400)) day\(gap >= 172_800 ? "s" : "")"
            : gap >= 7_200 ? "\(Int(gap / 3_600)) h" : "\(Int(gap / 60)) min"
    }

    private func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? "\((Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
            : count >= 1_000 ? "\(count / 1_000)K" : "\(count)"
    }

    private func dollars(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "under 1¢" : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
