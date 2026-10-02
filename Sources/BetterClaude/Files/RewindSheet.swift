import CoworkKit
import SwiftUI

/// What one conversation did to your files: each file's change, played step by step if you
/// like, and putting chosen files back as they were before it.
@MainActor
@Observable
final class RewindModel: Identifiable {
    enum Phase: Equatable { case loading, ready, done(Int), failed(String) }

    let conversation: ConversationRef
    nonisolated let id: String
    private(set) var changes: ConversationChanges?
    private(set) var phase: Phase = .loading
    var chosen: Set<String> = []
    private(set) var selected: String?
    /// Before the conversation to now, for the selected file.
    private(set) var diff: LineDiff?
    /// Lines added and removed, by file, once worked out.
    private(set) var counts: [String: (added: Int, removed: Int)] = [:]
    /// Choosing which files to put back.
    var choosing = false

    // Playing: the selected file through the conversation, one saved version at a time.
    private(set) var timelapse: Timelapse?
    /// The step shown; nil shows the whole change.
    private(set) var step: Int?
    private(set) var playing = false
    private let startsPlaying: Bool
    private var index: HistoryIndex?
    private var player: Task<Void, Never>?

    init(conversation: ConversationRef, playing: Bool = false) {
        self.conversation = conversation
        id = conversation.id
        startsPlaying = playing
    }

    func load(index: HistoryIndex?) {
        guard let index else { phase = .failed("The history index isn't ready yet."); return }
        self.index = index
        Task {
            do {
                let changes = try await ConversationRewind.changes(conversationID: conversation.id, index: index)
                self.changes = changes
                // Files changed since are left for you to choose; everything else starts chosen.
                chosen = Set(changes.puttable.filter { !$0.changedSince }.map(\.path))
                phase = .ready
                select(changes.files.first { $0.canPutBack && !$0.created }?.path
                       ?? changes.files.first(where: \.canPutBack)?.path ?? changes.files.first?.path)
                let files = changes.files
                counts = await Task.detached(priority: .utility) {
                    var counts: [String: (added: Int, removed: Int)] = [:]
                    for file in files {
                        if let diff = ConversationRewind.diff(for: file) { counts[file.path] = (diff.added, diff.removed) }
                    }
                    return counts
                }.value
                if startsPlaying { play() }
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    func select(_ path: String?) {
        stop()
        selected = path
        step = nil
        timelapse = nil
        guard let file = changes?.files.first(where: { $0.path == path }) else { diff = nil; return }
        Task {
            let computed = await Task.detached(priority: .userInitiated) { ConversationRewind.diff(for: file) }.value
            // A quicker click on another file may have finished first.
            guard selected == path else { return }
            diff = computed
            guard let index, let path else { return }
            let made = try? await Timelapse.load(conversationID: conversation.id, path: path, index: index)
            if selected == path { timelapse = made }
        }
    }

    /// Edits there are to step through.
    var steps: Int { max(0, (timelapse?.frames.count ?? 1) - 1) }

    var shownDiff: LineDiff? {
        if let step, step > 0, let change = timelapse?.change(into: step) { return change }
        return diff
    }

    var stepCaption: String? {
        guard let step, step > 0, let frame = timelapse?.frames[safe: step] else { return nil }
        guard let prompt = frame.prompt else { return "After the next turn" }
        let flat = prompt.replacingOccurrences(of: "\n", with: " ")
        return "After “\(flat.count > 90 ? String(flat.prefix(90)) + "…" : flat)”"
    }

    func play() {
        guard steps > 0 else { return }
        if (step ?? steps) >= steps { step = 0 }
        playing = true
        player = Task {
            while !Task.isCancelled, let current = step, current < steps {
                step = current + 1
                try? await Task.sleep(for: .milliseconds(1_400))
            }
            playing = false
        }
    }

    func stop() {
        player?.cancel()
        playing = false
    }

    func putBack() {
        guard let changes else { return }
        let files = changes.puttable.filter { chosen.contains($0.path) }
        do {
            try ConversationRewind.putBack(files, title: changes.title)
            phase = .done(files.count)
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Changes: a file list, the change as a diff, Play to step through it, and Put Back.
struct RewindSheet: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: RewindModel
    let onClose: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Changes").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.Surface.primary)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary).padding(.top, 3)

            Group {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                case .failed(let message):
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                case .done(let count):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Put back \(count) file\(count == 1 ? "" : "s").").font(.system(size: 13, weight: .semibold))
                        Text("What was there is saved first. Undo in History reverses it.")
                            .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                case .ready:
                    if let changes = model.changes, !changes.files.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            fileList(changes).frame(width: 220)
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(height: contentHeight(changes))
                        .clipped()
                    } else {
                        Text("This conversation didn't edit or create any files Claude Code kept versions of.")
                            .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    }
                }
            }
            .padding(.top, 16)

            footer.padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 760)
        .background(Theme.Surface.window)
        .onAppear { model.load(index: services.index.index) }
        .onDisappear { model.stop() }
        .confirmationDialog("Put back \(model.chosen.count) file\(model.chosen.count == 1 ? "" : "s")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Put Back") { model.putBack() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What's there now is saved first, and files the conversation created are taken away. Undo in History reverses all of it.")
        }
    }

    private var subtitle: String {
        let count = model.changes?.files.count ?? 0
        let title = model.conversation.title
        let short = title.count > 48 ? String(title.prefix(48)) + "…" : title
        return count == 0 ? "What “\(short)” did to your files" : "What “\(short)” did to \(count) file\(count == 1 ? "" : "s")"
    }

    private func fileList(_ changes: ConversationChanges) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(changes.files) { file in
                    HStack(alignment: .top, spacing: 8) {
                        if model.choosing {
                            Toggle("", isOn: Binding(
                                get: { model.chosen.contains(file.path) },
                                set: { on in if on { model.chosen.insert(file.path) } else { model.chosen.remove(file.path) } }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(!file.canPutBack)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.Surface.primary)
                                .lineLimit(1)
                            if file.changedSince {
                                Text("Changed again since").font(.system(size: 11.5)).foregroundStyle(Theme.attention)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(countText(file))
                            .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.selected == file.path ? Theme.Surface.selection : .clear,
                                in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                    .onTapGesture { model.select(file.path) }
                    .help(file.path)
                    .contextMenu { FileActions(path: file.path) }
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    /// As tall as the longer of the file list and the change, within reason.
    private func contentHeight(_ changes: ConversationChanges) -> CGFloat {
        let list = CGFloat(changes.files.count) * 34
        let lines = CGFloat(min(model.shownDiff?.lines.count ?? 4, 30)) * 14.4 + 18
        let play: CGFloat = model.steps > 0 ? 44 : 0
        return min(440, max(150, max(list, lines + play + (model.stepCaption == nil ? 0 : 26))))
    }

    private func countText(_ file: ConversationChanges.File) -> String {
        if file.created { return "new" }
        guard let count = model.counts[file.path] else { return "" }
        return "+\(count.added) −\(count.removed)"
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = model.stepCaption {
                Text(caption).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Surface.primary)
                    .lineLimit(2)
            }
            if let diff = model.shownDiff {
                if diff.isEmpty {
                    Text(model.step == nil ? "It's the same now as before this conversation." : "No change to this file in that turn.")
                        .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    DiffWell(diff: diff)
                }
            } else if model.selected != nil {
                Text("There's no text to compare for this file.")
                    .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if model.steps > 0 {
                HStack(spacing: 10) {
                    Button { model.playing ? model.stop() : model.play() } label: {
                        Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.space, modifiers: [])
                    ThinMeter(value: Double(model.step ?? model.steps) / Double(model.steps))
                    Text("\(model.step ?? model.steps) of \(model.steps)")
                        .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
                        .fixedSize()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let path = model.selected, case .ready = model.phase {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(.quiet)
                    .disabled(!FileManager.default.fileExists(atPath: path))
            }
            Spacer()
            if model.choosing {
                Button("Cancel") { model.choosing = false }.buttonStyle(.secondary)
                Button("Put Back \(model.chosen.count) File\(model.chosen.count == 1 ? "" : "s")…") { confirming = true }
                    .buttonStyle(.primary)
                    .disabled(model.chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { model.stop(); onClose() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                if case .ready = model.phase, let puttable = model.changes?.puttable, !puttable.isEmpty {
                    Button("Put Back \(model.chosen.count) File\(model.chosen.count == 1 ? "" : "s")…") { model.choosing = true }
                        .buttonStyle(.primary)
                }
            }
        }
    }
}

/// A change as text: removed lines in red, added in green, the rest quiet. Mono, in a well.
struct DiffWell: View {
    let diff: LineDiff
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines.prefix(600)) { line in
                    Text(prefix(line.kind) + line.text)
                        .foregroundStyle(color(line.kind))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(5)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .defaultScrollAnchor(.topLeading)
        // Long lines still scroll sideways; a bar that's always there would cover the last line.
        .scrollIndicators(.never, axes: .horizontal)
        // As tall as the diff when there's room, and shorter, scrolling, when there isn't:
        // a fixed height let the column spill over the sheet's title and buttons.
        .frame(maxHeight: contentHeight > 0 ? contentHeight : .infinity)
        .background(Theme.Surface.fill, in: .rect(cornerRadius: 8, style: .continuous))
    }

    private func prefix(_ kind: LineDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "− "
        case .context: return "  "
        case .gap: return "  ⋯"
        }
    }

    private func color(_ kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return Color(nsColor: .systemGreen)
        case .removed: return Color(nsColor: .systemRed)
        case .context, .gap: return Theme.Surface.secondary
        }
    }
}
