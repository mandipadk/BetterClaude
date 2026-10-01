import CoworkKit
import SwiftUI

/// Replaying a conversation's prompts on another model, with your own API key, to see how
/// its answers compare with the ones you got.
@MainActor
@Observable
final class ReplayModel: Identifiable {
    struct Result: Identifiable {
        let turn: Replay.Turn
        var reply: String?
        var failure: String?
        var id: Int { turn.number }
    }

    let conversation: ConversationRef
    nonisolated let id: String
    private(set) var turns: [Replay.Turn] = []
    var model = Replay.models[2]
    var count = 3
    private(set) var results: [Result] = []
    private(set) var running = false
    private(set) var spent: (input: Int, output: Int) = (0, 0)
    private(set) var loaded = false
    private var task: Task<Void, Never>?

    init(conversation: ConversationRef) {
        self.conversation = conversation
        id = conversation.id
    }

    func load(index: HistoryIndex?) {
        guard let index else { return }
        Task {
            let messages = (try? await index.messages(in: conversation.id, limit: 2_000)) ?? []
            turns = Replay.turns(from: messages)
            count = min(3, max(1, turns.count))
            loaded = true
        }
    }

    var chosen: [Replay.Turn] { Array(turns.prefix(count)) }
    var estimate: (inputTokens: Int, outputTokens: Int, dollars: Double) { Replay.estimate(chosen, model: model.identifier) }

    var actualCost: Double {
        Pricing.cost(model: model.identifier, input: Int64(spent.input), output: Int64(spent.output),
                     cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
    }

    func run() {
        guard let key = APIKeyStore.read() else { return }
        let client = AnthropicClient(key: key)
        let model = model.identifier
        results = chosen.map { Result(turn: $0) }
        spent = (0, 0)
        running = true
        task = Task {
            for index in results.indices {
                guard !Task.isCancelled else { break }
                do {
                    let reply = try await client.send(model: model, messages: Replay.messages(for: results[index].turn))
                    results[index].reply = reply.text
                    spent.input += reply.inputTokens
                    spent.output += reply.outputTokens
                } catch {
                    results[index].failure = String(describing: error)
                    if case AnthropicClient.Failure.http(let code, _) = error, code == 401 { break }
                }
            }
            running = false
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }
}

struct ReplaySheet: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: ReplayModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: "arrow.triangle.2.circlepath", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replay on another model").font(Theme.Font.title)
                    Text("Asks another model the same things, with the conversation as it was at each point, so you can compare its answers with the ones you got. Uses your API key.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !APIKeyStore.isSet {
                HStack {
                    Text("Add your Anthropic API key in Settings first. Replays are billed to it at API prices.")
                        .font(Theme.Font.body)
                    Spacer()
                    SettingsLink { Text("Open Settings…") }.buttonStyle(.bordered)
                }
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.turns.isEmpty {
                Text("This conversation has nothing to replay.").font(Theme.Font.body)
            } else if model.results.isEmpty {
                setup
            } else {
                results
            }

            HStack {
                Button(model.running ? "Stop" : "Close") {
                    if model.running { model.cancel() } else { onClose() }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.results.isEmpty {
                    Text(spentText).font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                } else if APIKeyStore.isSet, !model.turns.isEmpty {
                    Button("Replay \(model.count) Turn\(model.count == 1 ? "" : "s")") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: model.results.isEmpty ? 560 : 900)
        .onAppear { model.load(index: services.index.index) }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Model", selection: $model.model) {
                ForEach(Replay.models) { Text($0.name).tag($0) }
            }
            Stepper(value: $model.count, in: 1...min(12, model.turns.count)) {
                Text("The first \(model.count) of \(model.turns.count) turns").monospacedDigit()
            }
            let estimate = model.estimate
            Text("About \(dollars(estimate.dollars)) at list prices: roughly \(estimate.inputTokens.formatted()) tokens in and \(estimate.outputTokens.formatted()) out. Each turn resends the conversation up to that point.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(model.results) { result in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Turn \(result.turn.number)").font(Theme.Font.headline)
                        Text(result.turn.prompt)
                            .font(Theme.Font.body)
                            .lineLimit(4)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.control))
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            column("Then", result.turn.original ?? "No reply was recorded.")
                            if let reply = result.reply {
                                column("Now, \(model.model.name)", reply)
                            } else if let failure = result.failure {
                                column("Now, \(model.model.name)", failure)
                            } else {
                                VStack(alignment: .leading) {
                                    Text("Now, \(model.model.name)").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(.secondary)
                                    ProgressView().controlSize(.small)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 520)
    }

    private func column(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Font.callout.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownView(text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spentText: String {
        let done = model.results.filter { $0.reply != nil }.count
        return "\(done) of \(model.results.count) answered, \(dollars(model.actualCost)) spent"
    }

    private func dollars(_ value: Double) -> String {
        value < 0.01 ? "under a cent" : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
