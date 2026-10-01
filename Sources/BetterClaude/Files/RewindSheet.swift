import CoworkKit
import SwiftUI

/// What one conversation did to your files, and putting chosen files back as they were before it.
@MainActor
@Observable
final class RewindModel: Identifiable {
    enum Phase: Equatable { case loading, ready, done(Int), failed(String) }

    let conversation: ConversationRef
    nonisolated let id: String
    private(set) var changes: ConversationChanges?
    private(set) var phase: Phase = .loading
    var chosen: Set<String> = []
    var selected: String?
    private(set) var diff: LineDiff?

    init(conversation: ConversationRef) {
        self.conversation = conversation
        id = conversation.id
    }

    func load(index: HistoryIndex?) {
        guard let index else { phase = .failed("The history index isn't ready yet."); return }
        Task {
            do {
                let changes = try await ConversationRewind.changes(conversationID: conversation.id, index: index)
                self.changes = changes
                // Files changed since are left for you to choose; everything else starts chosen.
                chosen = Set(changes.puttable.filter { !$0.changedSince }.map(\.path))
                phase = .ready
                select(changes.files.first { $0.canPutBack && !$0.created }?.path
                       ?? changes.files.first(where: \.canPutBack)?.path ?? changes.files.first?.path)
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    func select(_ path: String?) {
        selected = path
        guard let file = changes?.files.first(where: { $0.path == path }) else { diff = nil; return }
        Task {
            diff = await Task.detached(priority: .userInitiated) { Self.diff(for: file) }.value
        }
    }

    nonisolated static func diff(for file: ConversationChanges.File) -> LineDiff? {
        // From now to before: what putting it back would do.
        ConversationRewind.diff(for: file, backwards: true)
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

struct RewindSheet: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: RewindModel
    let onClose: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: "clock.arrow.circlepath", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What this conversation changed").font(Theme.Font.title)
                    Text("Every file it edited or created, compared with how it was before. Put any of them back; Undo in History reverses it.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                Text(message).font(Theme.Font.body).foregroundStyle(.secondary)
            case .done(let count):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Put back \(count) file\(count == 1 ? "" : "s").").font(Theme.Font.headline)
                    Text("What was there is saved. To reverse it, choose Undo on this change in History.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            case .ready:
                if let changes = model.changes, !changes.files.isEmpty {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        fileList(changes)
                            .frame(width: 300)
                        preview
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(height: 420)
                } else {
                    Text("This conversation didn't edit or create any files.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }

            HStack {
                if case .done = model.phase {
                    Spacer()
                    Button("Done") { onClose() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { onClose() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if case .ready = model.phase, !model.chosen.isEmpty {
                        Button("Put Back \(model.chosen.count) File\(model.chosen.count == 1 ? "" : "s")…") { confirming = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 940)
        .onAppear { model.load(index: services.index.index) }
        .confirmationDialog("Put back \(model.chosen.count) file\(model.chosen.count == 1 ? "" : "s") as they were before this conversation?",
                            isPresented: $confirming) {
            Button("Put Back") { model.putBack() }
        } message: {
            Text("What's there now is saved first, and files the conversation created are taken away. Undo in History reverses all of it.")
        }
    }

    private func fileList(_ changes: ConversationChanges) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(changes.files) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { model.chosen.contains(file.path) },
                            set: { on in if on { model.chosen.insert(file.path) } else { model.chosen.remove(file.path) } }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!file.canPutBack)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                .font(Theme.Font.body)
                                .lineLimit(1)
                            Text(status(file))
                                .font(Theme.Font.caption)
                                .foregroundStyle(file.changedSince ? Theme.attention : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(model.selected == file.path ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.control))
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(file.path) }
                    .help(file.path)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let path = model.selected {
                Text(abbreviated(path))
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let file = model.changes?.files.first(where: { $0.path == path }), file.created {
                    Text(file.existsNow ? "The conversation created this file. Putting it back takes it away, keeping a copy for Undo."
                                        : "The conversation created this file, and it's already gone.")
                        .font(Theme.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diff = model.diff, !diff.isEmpty { DiffView(diff: diff) }
                } else if let diff = model.diff {
                    if diff.isEmpty {
                        Text("It's the same now as before this conversation.")
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Putting it back brings back \(diff.added) line\(diff.added == 1 ? "" : "s") and takes out \(diff.removed).")
                            .font(Theme.Font.callout)
                            .monospacedDigit()
                        DiffView(diff: diff)
                    }
                } else {
                    Text("There's no text to compare for this file.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func status(_ file: ConversationChanges.File) -> String {
        if file.before == nil { return "No copy saved before it changed" }
        if file.before?.copy == nil, file.before?.didNotExist == false { return "Its copy was cleaned up" }
        if file.changedSince { return "Changed again since" }
        if file.created { return file.existsNow ? "Created by it" : "Created by it, gone now" }
        return file.existsNow ? "Edited" : "Edited, gone now"
    }

    private func abbreviated(_ path: String) -> String {
        let home = HostPaths.current.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
