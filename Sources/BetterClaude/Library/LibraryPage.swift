import AppKit
import CoworkKit
import SwiftUI

/// Everything Claude has made, as a gallery: documents, images, code it gave you, what you
/// gave it, and the prompts you keep typing, each with the conversation it came from.
struct LibraryPage: View {
    @Environment(AppServices.self) private var services
    @AppStorage("libraryPreview") private var showsPreview = false

    var body: some View {
        @Bindable var library = services.library
        HStack(spacing: 0) {
            Group {
                if library.filter == .prompts {
                    LibraryPrompts()
                } else {
                    LibraryGallery()
                }
            }
            .frame(maxWidth: .infinity)
            if showsPreview, library.filter != .prompts, library.selected != nil {
                Rectangle().fill(Theme.Surface.line).frame(width: 0.5)
                ArtifactPreview()
                    .frame(width: 320)
                    .background(Theme.Surface.bar)
            }
        }
        .background(Theme.Surface.window)
        .task(id: services.generation) {
            if services.hasLoaded { services.library.gather(from: services.snapshot, generation: services.generation) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Segmented(options: LibraryFilter.allCases.map { ($0, $0.title) }, selection: $library.filter)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { showsPreview.toggle() } label: { Label("Preview", systemImage: "sidebar.right") }
                    .help("Show or hide the preview")
            }
            ToolbarItem(placement: .primaryAction) {
                SearchPill(prompt: "Search", width: 150) { services.showsPalette = true }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: Binding(get: { services.prompts.drafting.map(SkillSheet.Item.init) },
                             set: { if $0 == nil { services.prompts.drafting = nil } })) { item in
            SkillSheet(draft: item.draft) { services.prompts.drafting = nil }
                .environment(services)
        }
    }
}

/// Tiles, newest first, grouped by when Claude made them.
private struct LibraryGallery: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let library = services.library
        let artifacts = library.visible
        if library.summary == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Gathering what Claude made…").font(.system(size: 12.5)).foregroundStyle(Theme.Surface.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if artifacts.isEmpty {
            EmptyState(systemImage: "books.vertical", title: "Nothing here yet",
                       message: "What Claude makes in your conversations, documents, images and code, collects here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.groups(artifacts).prefix(library.filter == .everything ? 2 : 99), id: \.title) { group in
                        SectionLabel(title: group.title, top: group.title == Self.groups(artifacts).first?.title ? 0 : 26)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14, alignment: .top)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(group.items) { artifact in
                                LibraryTile(artifact: artifact, isSelected: library.selectedID == artifact.id)
                                    .onTapGesture { library.selectedID = artifact.id }
                                    .onTapGesture(count: 2) { open(artifact) }
                                    .contextMenu { LibraryItemActions(artifact: artifact) }
                            }
                        }
                    }
                    if library.filter == .everything, !services.prompts.prompts.isEmpty {
                        SectionLabel(title: "Prompts you keep typing", link: "All", action: { services.library.filter = .prompts })
                        Card {
                            ForEach(services.prompts.prompts.prefix(3)) { prompt in PromptRow(prompt: prompt) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 30)
            }
            .onAppear { if !services.prompts.loaded { services.prompts.load(paths: services.snapshot.paths) } }
        }
    }

    private func open(_ artifact: Artifact) {
        if let url = artifact.fileURL { NSWorkspace.shared.open(url) }
    }

    static func groups(_ artifacts: [Artifact]) -> [(title: String, items: [Artifact])] {
        let calendar = Calendar.current
        let now = Date()
        var order: [String] = []
        var buckets: [String: [Artifact]] = [:]
        for artifact in artifacts.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }) {
            let date = artifact.createdAt ?? .distantPast
            let title: String
            if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { title = "This week" }
            else if calendar.isDate(date, equalTo: now, toGranularity: .month) { title = "Earlier this month" }
            else if date == .distantPast { title = "Undated" }
            else { title = date.formatted(.dateTime.month(.wide).year()) }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(artifact)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

/// One thing Claude made: a preview of it, its name, and where it came from.
private struct LibraryTile: View {
    let artifact: Artifact
    let isSelected: Bool
    @State private var thumbnail: NSImage?
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.Surface.group
                preview
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentBright : Theme.Surface.line, lineWidth: isSelected ? 2.5 : 0.5)
            }
            Text(artifact.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Surface.primary)
                .lineLimit(1)
                .padding(.top, 7)
            Text(artifact.kind == .upload ? "You added it, \(artifact.conversationTitle)" : artifact.conversationTitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Surface.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .task(id: artifact.id) { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text {
            Text(text)
                .font(artifact.kind == .code ? .system(size: 9.5, design: .monospaced) : .system(size: 9.5))
                .foregroundStyle(Theme.Surface.secondary)
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let url = artifact.fileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        if let code = artifact.inlineContent {
            text = String(code.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n"))
        } else if let url = artifact.fileURL {
            if artifact.kind == .image || [.upload, .other].contains(artifact.kind) {
                thumbnail = await Thumbnails.load(url, size: 480)
            }
            if thumbnail == nil, [.document, .data].contains(artifact.kind) {
                text = await Task.detached {
                    guard let handle = try? FileHandle(forReadingFrom: url),
                          let data = try? handle.read(upToCount: 1_200) else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }.value
            }
        }
    }
}

/// A prompt you keep typing: what it says, how often, and making it a skill.
private struct PromptRow: View {
    @Environment(AppServices.self) private var services
    let prompt: PromptLibrary.Prompt

    var body: some View {
        Row(title: "“\(prompt.text.split(separator: "\n").first.map(String.init) ?? prompt.text)”",
            detail: "Used \(prompt.uses) times\(prompt.projects.isEmpty ? "" : " in \(prompt.projects.count) project\(prompt.projects.count == 1 ? "" : "s")")") {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt.text, forType: .string)
            }
            .buttonStyle(.secondary)
            Button("Make a Skill…") { services.prompts.drafting = SkillFactory.draft(from: prompt.text) }
                .buttonStyle(.secondary)
        }
    }
}

/// Prompts you keep typing, each a click from being a skill.
private struct LibraryPrompts: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let prompts = services.prompts
        PageScroll {
            SectionLabel(title: "Prompts you keep typing", top: 0)
            if prompts.loaded && prompts.prompts.isEmpty {
                Card { Row(title: "None yet", detail: "Prompts you've typed more than once show up here.") }
            } else {
                Card {
                    ForEach(prompts.prompts.prefix(40)) { prompt in PromptRow(prompt: prompt) }
                }
            }
        }
        .onAppear { if !prompts.loaded { prompts.load(paths: services.snapshot.paths) } }
    }
}

private struct ArtifactRow: View {
    let artifact: Artifact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ArtifactIcon(artifact: artifact, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(artifact.title).font(Theme.Font.bodyMedium).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = artifact.createdAt {
                        Text(date.listStamp)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(artifact.conversationTitle)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A file's own icon or thumbnail; code gets a drawn tile.
struct ArtifactIcon: View {
    let artifact: Artifact
    var size: CGFloat = 28
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let url = artifact.fileURL {
                Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .task(id: url) {
                        if artifact.kind == .image { thumbnail = await Thumbnails.load(url, size: size) }
                    }
            } else {
                GlyphTile(systemImage: "chevron.left.forwardslash.chevron.right", size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ImageTile: View {
    let artifact: Artifact
    let isSelected: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(Theme.subtleFill)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 104)
            .clipShape(.rect(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .task(id: artifact.fileURL) {
            if let url = artifact.fileURL { thumbnail = await Thumbnails.load(url, size: 208) }
        }
        .accessibilityLabel(artifact.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Preview

private struct ArtifactPreview: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if let artifact = services.library.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(artifact)
                    content(artifact)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(artifact.id)
        } else {
            EmptyState(systemImage: "square.stack",
                       title: "Pick something",
                       message: "Choose a file, an image or a piece of code to see it here, along with the conversation it came from.")
        }
    }

    private func header(_ artifact: Artifact) -> some View {
        let conversation = services.snapshot.conversations.first { $0.id == artifact.conversationID }
        return VStack(alignment: .leading, spacing: 10) {
            Text(artifact.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Surface.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let url = artifact.fileURL {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.primary)
                } else if let code = artifact.inlineContent {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.primary)
                }
                if let conversation {
                    Button("Open Conversation") { services.show(conversation) }.buttonStyle(.secondary)
                }
                Menu { LibraryItemActions(artifact: artifact) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.secondary).menuIndicator(.hidden).fixedSize()
            }
            VStack(alignment: .leading, spacing: 7) {
                if let conversation { KV("From", conversation.title) }
                if !artifact.container.isEmpty { KV("In", artifact.container) }
                KV("Kind", kindName(artifact))
                KV("Size", Int64(artifact.bytes).fileSize)
                if let date = artifact.createdAt { KV("Made", date.listStamp) }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func content(_ artifact: Artifact) -> some View {
        if let code = artifact.inlineContent {
            CodeWell(language: artifact.language, text: code)
        } else if let url = artifact.fileURL {
            if artifact.kind == .image, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 520)
                    .clipShape(.rect(cornerRadius: Theme.Radius.tile))
            } else if let text = readableText(url) {
                if url.pathExtension.lowercased() == "md" {
                    MarkdownView(text).fixedSize(horizontal: false, vertical: true)
                } else {
                    CodeWell(language: url.pathExtension, text: text)
                }
            } else {
                FilePreviewTile(url: url)
            }
        }
    }

    private func readableText(_ url: URL) -> String? {
        let textual: Set<String> = ["md", "txt", "csv", "json", "yaml", "yml", "html", "css", "js", "ts",
                                    "py", "swift", "sh", "sql", "xml", "tsv", "log", "toml"]
        guard textual.contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 40_000) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func kindName(_ artifact: Artifact) -> String {
        switch artifact.kind {
        case .code: return artifact.language.map { CodeWell.languageName($0) } ?? "Code"
        case .document: return "Document"
        case .data: return "Data"
        case .image: return "Image"
        case .upload: return "Upload"
        case .other: return artifact.fileURL?.pathExtension.uppercased() ?? "File"
        }
    }

}

/// A file without an inline preview: its Quick Look thumbnail, large.
private struct FilePreviewTile: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
            Text(url.lastPathComponent).font(Theme.Font.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .task(id: url) { thumbnail = await Thumbnails.load(url, size: 640) }
    }
}

/// What you can do with something in the library, for its ⋯ menu and its context menu.
struct LibraryItemActions: View {
    @Environment(AppServices.self) private var services
    let artifact: Artifact

    var body: some View {
        if let conversation = services.snapshot.conversations.first(where: { $0.id == artifact.conversationID }) {
            Button("Open Conversation") { services.show(conversation) }
        }
        if let url = artifact.fileURL {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy File Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
        if let code = artifact.inlineContent {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            Button("Save As…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = artifact.title.replacingOccurrences(of: "/", with: "-")
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    try? Data(code.utf8).write(to: url, options: .atomic)
                }
            }
        }
    }
}
