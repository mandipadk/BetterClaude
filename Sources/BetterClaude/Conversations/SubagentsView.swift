import CoworkKit
import SwiftUI

/// Under a conversation's header: the sub-agents it spawned, each with what it was asked,
/// what it came back with, and what it cost.
struct SubagentsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: ConversationRef
    /// In the inspector: no disclosure, the detail straight away.
    var alwaysOpen = false
    /// Narrow, for the inspector: shorter lane labels.
    var compact = false
    @AppStorage("subagentsOpen") private var open = false
    @State private var runs: [Subagents.Run] = []
    @State private var expanded: Set<String> = []
    @State private var ownReplies: [Date] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !runs.isEmpty {
                if !alwaysOpen { Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { open.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(runs.count == 1 ? "1 sub-agent" : "\(runs.count) sub-agents").font(Theme.Font.headline)
                        Text(summary)
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain) }

                if open || alwaysOpen {
                    if runs.contains(where: { $0.started != nil }) { timeline }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(runs) { run in row(run) }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Theme.Space.l)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
                    .transition(.opacity)
                }
            }
        }
        .task(id: "\(conversation.id)#\(services.index.generation)") {
            guard let index = services.index.index else { return }
            runs = (try? await Subagents.runs(conversationID: conversation.id, index: index)) ?? []
            guard !runs.isEmpty else { return }
            ownReplies = (try? await FlightRecord.load(conversationID: conversation.id, index: index))?.replies.map(\.timestamp) ?? []
        }
    }

    /// Who was working when: the conversation's own replies and each sub-agent, as lanes.
    private var timeline: some View {
        let lanes = laneData
        let start = lanes.flatMap { $0.spans.map(\.0) }.min() ?? Date()
        let end = lanes.flatMap { $0.spans.map(\.1) }.max() ?? start
        let length = max(60, end.timeIntervalSince(start))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Who was working when").font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(lanes, id: \.id) { lane in
                HStack(spacing: 10) {
                    Text(lane.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(lane.depth == 0 ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(max(0, lane.depth - 1)) * 12)
                        .frame(width: compact ? 104 : 190, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline).frame(height: 2)
                            ForEach(Array(lane.spans.enumerated()), id: \.offset) { _, span in
                                let x = geometry.size.width * span.0.timeIntervalSince(start) / length
                                let width = max(6, geometry.size.width * span.1.timeIntervalSince(span.0) / length)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(lane.failed ? Theme.attention : Theme.accent.opacity(lane.depth == 0 ? 0.9 : 0.55))
                                    .frame(width: min(width, geometry.size.width - x), height: 10)
                                    .offset(x: x)
                            }
                        }
                        .frame(height: geometry.size.height)
                    }
                    .frame(height: 14)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline of the conversation and its \(runs.count) sub-agents")
    }

    private struct Lane {
        let id: String
        let label: String
        let depth: Int
        let spans: [(Date, Date)]
        let failed: Bool
    }

    private var laneData: [Lane] {
        var lanes: [Lane] = []
        // The conversation's own work, as stretches of replies less than five minutes apart.
        var spans: [(Date, Date)] = []
        for at in ownReplies.sorted() {
            if let last = spans.last, at.timeIntervalSince(last.1) < 300 { spans[spans.count - 1].1 = at } else { spans.append((at, at)) }
        }
        let first = runs.compactMap(\.started).min() ?? .distantPast
        let last = runs.compactMap(\.ended).max() ?? .distantFuture
        // Only the stretch around the sub-agents, so the lanes line up at a readable scale.
        let near = spans.filter { $0.1 >= first.addingTimeInterval(-1_800) && $0.0 <= last.addingTimeInterval(1_800) }
        if !near.isEmpty { lanes.append(Lane(id: "main", label: "Claude", depth: 0, spans: near, failed: false)) }
        for (offset, run) in runs.enumerated() {
            guard let start = run.started else { continue }
            lanes.append(Lane(id: run.agentID, label: "\(offset + 1). \(run.title)", depth: run.depth,
                              spans: [(start, run.ended ?? start)], failed: run.result == nil))
        }
        return lanes
    }

    private var summary: String {
        let cost = runs.reduce(0) { $0 + $1.cost }
        let replies = runs.reduce(0) { $0 + $1.replies }
        let deepest = runs.map(\.depth).max() ?? 1
        var text = "\(dollars(cost)) over \(replies) replies"
        if deepest > 1 { text += ", \(deepest) levels deep" }
        return text + "."
    }

    private func row(_ run: Subagents.Run) -> some View {
        let isOpen = expanded.contains(run.agentID)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : Theme.Motion.snappy) {
                    if isOpen { expanded.remove(run.agentID) } else { expanded.insert(run.agentID) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title).font(Theme.Font.body).lineLimit(1)
                        Text(facts(run)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        if run.ranOnOtherModel, let asked = run.requestedModel, let model = run.model {
                            Text("Asked for \(asked.prefix(1).uppercased() + asked.dropFirst()), ran on \(humanModelName(model))")
                                .font(Theme.Font.caption).foregroundStyle(Theme.attention)
                        }
                        if run.result == nil {
                            Text("Ended without replying").font(Theme.Font.caption).foregroundStyle(Theme.attention)
                        }
                    }
                    Spacer(minLength: Theme.Space.m)
                    Text(dollars(run.cost)).font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let prompt = run.prompt {
                        Text("Asked").font(Theme.Font.caption).foregroundStyle(.secondary)
                        MarkdownView(String(prompt.prefix(1_500)) + (prompt.count > 1_500 ? "…" : ""))
                            .textSelection(.enabled)
                    }
                    if let result = run.result {
                        Text("Came back with").font(Theme.Font.caption).foregroundStyle(.secondary)
                        MarkdownView(String(result.prefix(3_000)) + (result.count > 3_000 ? "…" : ""))
                            .textSelection(.enabled)
                    } else {
                        Text("It ended without a final reply.").font(Theme.Font.callout).foregroundStyle(Theme.attention)
                    }
                }
                .padding(.leading, 19)
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, CGFloat(max(0, run.depth - 1)) * 18)
        .overlay(alignment: .top) { if run.agentID != runs.first?.agentID { Rectangle().fill(Theme.hairline).frame(height: 1) } }
    }

    private func facts(_ run: Subagents.Run) -> String {
        var parts: [String] = []
        if let type = run.type { parts.append(type == "general-purpose" ? "General" : type) }
        if let model = run.model { parts.append(humanModelName(model)) }
        parts.append("\(run.replies) repl\(run.replies == 1 ? "y" : "ies")")
        if run.tools > 0 { parts.append("\(run.tools) tool\(run.tools == 1 ? "" : "s")") }
        if let start = run.started, let end = run.ended {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            parts.append(minutes < 1 ? "under a minute" : "\(minutes) min")
        }
        return parts.joined(separator: ", ")
    }

    private func dollars(_ value: Double) -> String { Pricing.dollars(value) }
}
