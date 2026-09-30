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
                        .foregroundStyle(change.cause == .unexplained ? Theme.attention : .secondary)
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
                                services.filter = .all
                                services.destination = .conversations
                                services.selectedConversationID = item.change.conversationID
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
