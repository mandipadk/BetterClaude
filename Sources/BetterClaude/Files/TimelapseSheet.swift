import CoworkKit
import SwiftUI

/// A file through a conversation, step by step, each change beside what was asked for it.
@MainActor
@Observable
final class TimelapseModel: Identifiable {
    let conversation: ConversationRef
    nonisolated let id: String
    private(set) var files: [String] = []
    private(set) var timelapse: Timelapse?
    private(set) var loaded = false
    var step = 0
    var file: String? {
        didSet { if file != oldValue { loadTimelapse() } }
    }
    private(set) var playing = false
    private var index: HistoryIndex?
    private var player: Task<Void, Never>?

    init(conversation: ConversationRef) {
        self.conversation = conversation
        id = conversation.id
    }

    func load(index: HistoryIndex?) {
        guard let index else { return }
        self.index = index
        Task {
            files = (try? await Timelapse.files(conversationID: conversation.id, index: index)) ?? []
            loaded = true
            file = files.first
        }
    }

    private func loadTimelapse() {
        stop()
        guard let index, let file else { timelapse = nil; return }
        Task {
            let made = try? await Timelapse.load(conversationID: conversation.id, path: file, index: index)
            guard made?.path == self.file else { return }
            timelapse = made
            step = min(1, max(0, (made?.frames.count ?? 1) - 1))
        }
    }

    func play() {
        guard let count = timelapse?.frames.count, count > 1 else { return }
        if step >= count - 1 { step = 0 }
        playing = true
        player = Task {
            while !Task.isCancelled, step < count - 1 {
                try? await Task.sleep(for: .milliseconds(1_400))
                guard !Task.isCancelled else { break }
                step += 1
            }
            playing = false
        }
    }

    func stop() {
        player?.cancel()
        playing = false
    }
}

struct TimelapseSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: TimelapseModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: "film.stack", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch it change").font(Theme.Font.title)
                    Text("A file through this conversation, step by step, from the versions Claude Code saved, each beside what was asked.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.files.count > 1 {
                    Picker("File", selection: $model.file) {
                        ForEach(model.files, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(Optional(path))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }

            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if model.files.isEmpty {
                Text("Claude Code didn't save versions of any file in this conversation.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else if let timelapse = model.timelapse, timelapse.frames.count > 1 {
                stage(timelapse)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }

            HStack {
                Button("Close") { model.stop(); onClose() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 900)
        .onAppear { model.load(index: services.index.index) }
        .onDisappear { model.stop() }
    }

    private func stage(_ timelapse: Timelapse) -> some View {
        let last = timelapse.frames.count - 1
        let frame = timelapse.frames[min(model.step, last)]
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Button { model.playing ? model.stop() : model.play() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .buttonStyle(.secondary)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.playing ? "Pause" : "Play through every step")
                Slider(value: Binding(get: { Double(model.step) }, set: { model.step = Int($0.rounded()) }),
                       in: 0...Double(last), step: 1)
                Text("Step \(model.step) of \(last)")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                if model.step == 0 {
                    Text(frame.text == nil ? "Before: the file didn't exist yet." : "Before the conversation changed it.")
                        .font(Theme.Font.headline)
                } else {
                    Text(frame.prompt.map { "After “\(oneLine($0))”" } ?? "After the next turn")
                        .font(Theme.Font.headline)
                        .lineLimit(2)
                }
                if let date = frame.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(model.step)
            .transition(.opacity)
            .animation(reduceMotion ? nil : Theme.Motion.fade, value: model.step)

            if model.step > 0, let diff = timelapse.change(into: model.step) {
                if diff.isEmpty {
                    Text("No change to this file in that turn.").font(Theme.Font.body).foregroundStyle(.secondary)
                } else {
                    Text("\(diff.added) line\(diff.added == 1 ? "" : "s") added, \(diff.removed) removed")
                        .font(Theme.Font.callout)
                        .monospacedDigit()
                    DiffView(diff: diff)
                }
            } else if let text = frame.text {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(Theme.Font.code)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 420)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            }
        }
        .frame(minHeight: 460, alignment: .top)
    }

    private func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 110 ? String(flat.prefix(110)) + "…" : flat
    }
}
