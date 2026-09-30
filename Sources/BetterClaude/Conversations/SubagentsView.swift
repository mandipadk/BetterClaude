import CoworkKit
import SwiftUI

/// Under a conversation's header: the sub-agents it spawned, each with what it was asked,
/// what it came back with, and what it cost.
struct SubagentsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: ConversationRef
    @AppStorage("subagentsOpen") private var open = false
    @State private var runs: [Subagents.Run] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !runs.isEmpty {
                Button {
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
                .buttonStyle(.plain)

                if open {
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
        }
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

    private func dollars(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "under 1¢" : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
