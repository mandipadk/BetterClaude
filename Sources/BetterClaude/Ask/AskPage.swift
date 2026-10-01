import CoworkKit
import SwiftUI

/// Ask a question about your past work, answered on this Mac from your own conversations.
struct AskPage: View {
    @Environment(AppServices.self) private var services
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ask = services.ask
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask").font(Theme.Font.display)
                    Text("A question about your past work, answered from your own conversations by the model built into macOS. Nothing leaves this Mac.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Theme.Space.xl)

                field(ask)
                    .padding(.bottom, Theme.Space.xl)

                if case .unavailable(let reason) = ask.availability {
                    DetailSection(title: "Not available on this Mac") {
                        Text("\(reason) You can still search every message from the search field above the timeline.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    result(ask)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { focused = true }
    }

    private func field(_ ask: AskModel) -> some View {
        @Bindable var ask = ask
        let working = ask.phase == .searching || ask.phase == .answering
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("What did we decide about the retry limit?", text: $ask.question)
                .textFieldStyle(.plain)
                .font(Theme.Font.reading)
                .focused($focused)
                .onSubmit { ask.ask(index: services.index.index) }
                .disabled(ask.availability != .available)
            if working {
                Button("Stop") { ask.cancel() }
                    .buttonStyle(.secondary)
            } else {
                Button("Ask") { ask.ask(index: services.index.index) }
                    .buttonStyle(.primary)
                    .disabled(ask.question.trimmingCharacters(in: .whitespaces).isEmpty
                              || ask.availability != .available || !services.index.isReady)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
    }

    @ViewBuilder
    private func result(_ ask: AskModel) -> some View {
        switch ask.phase {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking through your conversations…").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
        case .nothingFound:
            DetailSection(title: "Nothing found") {
                Text("No conversation mentions the words in “\(ask.askedQuestion)”. Try the words you'd have used at the time.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            DetailSection(title: "No answer") {
                Text(message).font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            sourcesSection(ask)
        case .answering, .done:
            DetailSection(title: ask.askedQuestion) {
                if ask.answer.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(ask.sources.count) conversation\(ask.sources.count == 1 ? "" : "s")…")
                            .font(Theme.Font.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(cited(ask.answer))
                        .font(Theme.Font.reading)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            sourcesSection(ask)
        }
    }

    @ViewBuilder
    private func sourcesSection(_ ask: AskModel) -> some View {
        if !ask.shownSources.isEmpty {
            DetailSection(title: "From", subtitle: "The conversations the answer was drawn from. Open one to check it.") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ask.shownSources) { source in
                        Button { open(source) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                                Text("\(source.number)")
                                    .font(Theme.Font.callout.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .monospacedDigit()
                                    .frame(width: 18, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).font(Theme.Font.bodyMedium).lineLimit(1)
                                    Text(placeLine(source))
                                        .font(Theme.Font.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func placeLine(_ source: AskRetrieval.Source) -> String {
        let place = source.place.prefix(1).uppercased() + source.place.dropFirst()
        guard let date = source.lastActivity else { return place }
        return "\(place), \(date.listStamp.lowercasedIfWordLocal)"
    }

    private func open(_ source: AskRetrieval.Source) {
        if let conversation = services.snapshot.conversations.first(where: { $0.id == source.conversationID }) {
            services.show(conversation)
        }
    }

    /// The answer with its citations picked out in the accent.
    private func cited(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let pattern = /\[\d+(?:,\s*\d+)*\]/
        for match in text.matches(of: pattern) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = Theme.accent
            result[lower..<upper].font = Theme.Font.reading.weight(.semibold)
        }
        return result
    }
}
