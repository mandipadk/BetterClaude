import CoworkKit
import SwiftUI

/// Under a conversation's header, when its replies changed model: when, to what, and whether
/// anyone asked for it.
struct ModelSwitchesView: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    @State private var switches: [ModelDrift.Switch] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(switches.prefix(3)) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: change.cause == .unexplained ? "exclamationmark.triangle" : "arrow.triangle.swap")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(ModelSwitchesView.sentence(change))
                        .font(Theme.Font.callout)
                        .foregroundStyle(change.cause == .unexplained ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if switches.count > 3 {
                Text("And \(switches.count - 3) more changes of model.").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(conversation.id)#\(services.index.generation)") {
            guard let index = services.index.index else { return }
            switches = (try? await ModelDrift.switches(conversationID: conversation.id, index: index)) ?? []
        }
    }

    static func sentence(_ change: ModelDrift.Switch) -> String {
        let when = change.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let to = humanModelName(change.to), from = humanModelName(change.from)
        let since = "\(change.replies) repl\(change.replies == 1 ? "y" : "ies") from it"
        switch change.cause {
        case .requested: return "You switched from \(from) to \(to) on \(when). \(since.prefix(1).uppercased() + since.dropFirst())."
        case .fallback: return "Claude Code fell back from \(from) to \(to) after a refusal on \(when), \(since)."
        case .unexplained: return "Replies switched from \(from) to \(to) on \(when) without a request, \(since)."
        }
    }
}

/// On Usage: every change of model nobody asked for, in the last month.
struct ModelDriftSection: View {
    @Environment(AppServices.self) private var services
    @State private var found: [(title: String, change: ModelDrift.Switch)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !found.isEmpty {
                DetailSection(title: "Models that changed on their own",
                              subtitle: "Conversations whose replies came from a different model partway through, with no /model or fallback on record. Worth knowing when comparing what a session cost or how it did.") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(found.prefix(8), id: \.change.id) { item in
                            Button {
                                services.show(conversationID: item.change.conversationID)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(Theme.Font.body).foregroundStyle(Theme.accent).lineLimit(1)
                                    Text("\(humanModelName(item.change.from)) to \(humanModelName(item.change.to)), \(item.change.at.listStamp.lowercasedIfWordLocal), \(item.change.replies) replies since")
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: services.index.generation) {
            guard let index = services.index.index else { return }
            found = (try? await ModelDrift.unexplained(index: index, since: Date().addingTimeInterval(-30 * 86_400))) ?? []
        }
    }
}

/// On Usage: what coming back after the prompt cache expired cost this month.
struct CacheBreaksSection: View {
    @Environment(AppServices.self) private var services
    @State private var summary: CacheBreaks.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary, summary.breaks > 0 {
                DetailSection(title: "Coming back after a break",
                              subtitle: "Each reply keeps the conversation in Claude's cache for \(summary.hourLong ? "an hour" : "five minutes"). After a longer break, the next reply writes all of it into the cache again, at many times the price of reading it.") {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Text("In the last 30 days, \(summary.breaks) repl\(summary.breaks == 1 ? "y" : "ies") re-read a conversation after its cache expired: \(tokens(summary.tokens)) tokens, about \(dollars(summary.extra)) more at list prices than reading them from the cache.")
                            .font(Theme.Font.body)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.projects.prefix(5), id: \.name) { project in
                                HStack {
                                    Text(project.name).font(Theme.Font.callout)
                                    Spacer()
                                    Text("\(project.breaks) time\(project.breaks == 1 ? "" : "s"), \(dollars(project.extra))")
                                        .font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        Text("Before stepping away from a long conversation, compacting it or writing a handoff costs less than re-reading it later.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task(id: services.index.generation) {
            guard let index = services.index.index else { return }
            summary = try? await CacheBreaks.summary(index: index, since: Date().addingTimeInterval(-30 * 86_400))
        }
    }

    private func tokens(_ count: Int64) -> String {
        count >= 1_000_000 ? "\((Double(count) / 1e6).formatted(.number.precision(.fractionLength(0...1))))M" : "\(count / 1_000)K"
    }

    private func dollars(_ value: Double) -> String { Pricing.dollars(value) }
}
