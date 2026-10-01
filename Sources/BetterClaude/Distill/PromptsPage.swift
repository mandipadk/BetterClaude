import AppKit
import CoworkKit
import SwiftUI

/// The prompts you keep typing, and a way to turn one into a skill Claude Code can use.
@MainActor
@Observable
final class PromptsModel {
    private(set) var prompts: [PromptLibrary.Prompt] = []
    private(set) var loaded = false
    var selectedID: String?
    var drafting: SkillFactory.Draft?

    func load(paths: HostPaths) {
        Task {
            let found = await Task.detached(priority: .utility) {
                PromptLibrary.repeated(configDirs: LiveSessions.configDirs(paths: paths), minimumUses: 2, paths: paths)
            }.value
            prompts = found
            loaded = true
            if selectedID == nil { selectedID = found.first?.id }
        }
    }

    var selected: PromptLibrary.Prompt? { prompts.first { $0.id == selectedID } }
}

struct PromptsPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var model = services.prompts
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompts").font(Theme.Font.title)
                    Text(model.loaded ? "\(model.prompts.count) you've typed more than once" : "Reading what you've typed…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                List(selection: $model.selectedID) {
                    ForEach(model.prompts) { prompt in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.text.replacingOccurrences(of: "\n", with: " "))
                                .font(Theme.Font.body)
                                .lineLimit(2)
                            Text(usage(prompt))
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(prompt.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 360)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                if let prompt = model.selected {
                    PromptDetail(prompt: prompt)
                } else {
                    EmptyState(systemImage: "text.quote", title: model.loaded ? "Nothing repeated yet" : "Reading…",
                               message: "Prompts you type in Claude Code more than once show up here, so you can reuse them or make them a skill.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if !model.loaded { model.load(paths: services.snapshot.paths) } }
        .sheet(item: Binding(get: { model.drafting.map(SkillSheet.Item.init) }, set: { if $0 == nil { model.drafting = nil } })) { item in
            SkillSheet(draft: item.draft) { model.drafting = nil }
                .environment(services)
        }
    }

    private func usage(_ prompt: PromptLibrary.Prompt) -> String {
        var text = "\(prompt.uses) times"
        if let last = prompt.lastUsed { text += ", last \(last.listStamp.lowercasedIfWordLocal)" }
        if prompt.variants > 0 { text += ", in \(prompt.variants + 1) wordings" }
        return text
    }
}

private struct PromptDetail: View {
    @Environment(AppServices.self) private var services
    let prompt: PromptLibrary.Prompt
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Used \(prompt.uses) times").font(Theme.Font.display)
                Text(prompt.text)
                    .font(Theme.Font.reading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
                if !prompt.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("In").font(Theme.Font.callout).foregroundStyle(.secondary)
                        ForEach(prompt.projects.prefix(5), id: \.self) { project in
                            Text(services.snapshot.paths.abbreviating(project)).font(Theme.Font.body)
                        }
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.text, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    Button("Make a Skill…") { services.prompts.drafting = SkillFactory.draft(from: prompt.text) }
                        .buttonStyle(.borderedProminent)
                }
                Text("A skill is instructions Claude Code loads when they apply, so you can stop typing this.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(prompt.id)
    }
}

/// Reviewing a skill draft and adding it to Claude Code.
struct SkillSheet: View {
    struct Item: Identifiable {
        let draft: SkillFactory.Draft
        var id: String { draft.name + draft.body }
    }

    @Environment(AppServices.self) private var services
    @State var draft: SkillFactory.Draft
    let onClose: () -> Void
    @State private var configDir: URL?
    @State private var failure: String?
    @State private var done = false

    init(draft: SkillFactory.Draft, onClose: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: "wand.and.stars", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(done ? "Skill added" : "Make a skill").font(Theme.Font.title)
                    Text(done
                         ? "Claude Code picks it up in new sessions. Undo it from History."
                         : "Edit it as you like. Claude Code uses the description to decide when the skill applies.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !done {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(Theme.Font.callout).foregroundStyle(.secondary)
                    TextField("name", text: $draft.name).textFieldStyle(.roundedBorder)
                    Text("Description").font(Theme.Font.callout).foregroundStyle(.secondary)
                    TextField("When to use it", text: $draft.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Text("Instructions").font(Theme.Font.callout).foregroundStyle(.secondary)
                    TextEditor(text: $draft.body)
                        .font(Theme.Font.body)
                        .frame(height: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.control))
                }
                if services.pulse.configDirs.count > 1 {
                    Picker("Add to", selection: $configDir) {
                        ForEach(services.pulse.configDirs, id: \.self) { dir in
                            Text(services.snapshot.paths.abbreviating(dir.path)).tag(Optional(dir))
                        }
                    }
                }
                if let failure {
                    Text(failure).font(Theme.Font.callout).foregroundStyle(Theme.failure)
                } else if !SkillFactory.isValidName(draft.name) {
                    Text("A name can only have lowercase letters, numbers and hyphens.")
                        .font(Theme.Font.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if done {
                    Button("Done") { onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { onClose() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                    Button("Add to Claude Code") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!SkillFactory.isValidName(draft.name) || draft.description.isEmpty)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
    }

    private func add() {
        let dir = configDir ?? services.snapshot.paths.claudeCodeConfigDir
        do {
            try SkillFactory.install(draft, in: dir)
            done = true
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }
}
