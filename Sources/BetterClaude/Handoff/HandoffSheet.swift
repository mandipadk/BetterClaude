import AppKit
import CoworkKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a handoff brief for one conversation and offers what to do with it.
@MainActor
@Observable
final class HandoffModel: Identifiable {
    let conversation: ConversationRef
    nonisolated let id: String
    private(set) var brief = ""
    private(set) var isWriting = true
    /// Whether the model built into macOS tightened the brief.
    private(set) var polished = false
    private(set) var material: HandoffMaterial?
    private var task: Task<Void, Never>?

    init(conversation: ConversationRef) {
        self.conversation = conversation
        id = conversation.id
    }

    func start(index: HistoryIndex?, paths: HostPaths) {
        guard let index else { brief = "The history index isn't ready yet."; isWriting = false; return }
        task = Task {
            guard let material = try? await Handoff.material(for: conversation.id, index: index) else {
                brief = "This conversation hasn't been read into the index yet. Try again in a moment."
                isWriting = false
                return
            }
            self.material = material
            brief = Handoff.draft(material, home: paths)
            await polish(material, paths: paths)
            isWriting = false
        }
    }

    func cancel() { task?.cancel() }

    private func polish(_ material: HandoffMaterial, paths: HostPaths) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: Handoff.instructions)
            do {
                var text = ""
                for try await snapshot in session.streamResponse(to: Handoff.prompt(material, home: paths, budget: 9_000),
                                                                 options: GenerationOptions(temperature: 0.2)) {
                    try Task.checkCancellation()
                    text = snapshot.content
                }
                text = Handoff.sectionsOnly(text)
                guard !text.isEmpty else { return }
                // The model writes the thinking; the facts it might drop stay attached below.
                var out = "# Handoff: \(material.title)\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                if !material.filesChanged.isEmpty {
                    out += "## Files changed\n\n" + material.filesChanged.map { "- `\(paths.abbreviating($0))`" }.joined(separator: "\n") + "\n\n"
                }
                if let ask = material.lastAsk ?? material.firstAsk {
                    out += "## The last thing asked\n\n\(ask.count > 1_200 ? String(ask.prefix(1_200)) + "…" : ask)\n"
                }
                brief = out
                polished = true
            } catch {
                // The plain brief stays.
            }
        }
        #endif
    }
}

struct HandoffSheet: View {
    @Environment(AppServices.self) private var services
    let model: HandoffModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                GlyphTile(systemImage: "doc.text", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handoff").font(Theme.Font.title)
                    Text(subtitle)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWriting { ProgressView().controlSize(.small) }
            }
            ScrollView {
                MarkdownView(model.brief)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
            }
            .frame(minHeight: 320, maxHeight: 460)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            HStack(spacing: Theme.Space.s) {
                Button("Close") { model.cancel(); onClose() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save…") { save() }
                    .buttonStyle(.secondary)
                    .disabled(model.brief.isEmpty)
                Button("Copy") { copy() }
                    .buttonStyle(.secondary)
                    .disabled(model.brief.isEmpty)
                Button("Start in Claude Code") { startInClaudeCode() }
                    .buttonStyle(.primary)
                    .disabled(model.isWriting || model.brief.isEmpty)
                    .help("Opens Terminal in the conversation's folder and starts Claude Code with this brief")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
        .onAppear { model.start(index: services.index.index, paths: services.snapshot.paths) }
    }

    private var subtitle: String {
        if model.isWriting { return "Writing a brief of “\(model.conversation.title)”…" }
        return model.polished
            ? "A brief of “\(model.conversation.title)”, tightened on this Mac by the model built into macOS."
            : "A brief of “\(model.conversation.title)”, from what Claude recorded."
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.brief, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Handoff - \(model.conversation.title.prefix(60)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(model.brief.utf8).write(to: url, options: .atomic)
    }

    private func startInClaudeCode() {
        var folder = model.conversation.projectPath ?? model.material?.projectPath
        if folder == nil || !FileManager.default.fileExists(atPath: folder!) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Start Here"
            panel.message = "Choose the folder Claude Code should work in."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url.path
        }
        guard let folder else { return }
        services.startClaudeCode(in: folder, brief: model.brief, title: model.conversation.title)
        onClose()
    }
}
