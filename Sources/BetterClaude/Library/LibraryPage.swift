import AppKit
import CoworkKit
import SwiftUI

/// Everything Claude has made: files it wrote, images, code it gave you, and what you gave
/// it — each with the conversation it came from.
struct LibraryPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            LibraryColumn()
                .frame(width: 380)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ArtifactPreview()
                .frame(maxWidth: .infinity)
        }
        .task(id: services.generation) {
            if services.hasLoaded { services.library.gather(from: services.snapshot, generation: services.generation) }
        }
    }
}

private struct LibraryColumn: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var library = services.library
        let artifacts = library.visible
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library").font(Theme.Font.title)
                    Text(countText(artifacts.count))
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Picker("Show", selection: $library.filter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                FindField(text: $library.query, prompt: "Search the library")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if library.summary == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Gathering what Claude made…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if artifacts.isEmpty {
                EmptyState(systemImage: "square.stack", title: "Nothing here",
                           message: library.query.isEmpty
                               ? "Nothing of this kind has been made in any conversation yet."
                               : "Nothing in the library matches “\(library.query)”.")
            } else if library.filter == .images {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(artifacts) { artifact in
                            ImageTile(artifact: artifact, isSelected: library.selectedID == artifact.id) {
                                library.selectedID = artifact.id
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                List(selection: $library.selectedID) {
                    ForEach(artifacts) { artifact in
                        ArtifactRow(artifact: artifact).tag(artifact.id).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
    }

    private func countText(_ count: Int) -> String {
        guard let summary = services.library.summary else { return "Looking through every conversation…" }
        let conversations = summary.conversationsScanned
        return "\(count) \(count == 1 ? "item" : "items") from \(conversations) conversations"
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
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header(artifact)
                    content(artifact)
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 48)
                .frame(maxWidth: 760, alignment: .leading)
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
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text(artifact.title)
                    .font(Theme.Font.display)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = artifact.fileURL {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent)
                } else if let code = artifact.inlineContent {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                }
                MoreMenu {
                    if let conversation {
                        Button("Show Conversation") { services.show(conversation) }
                    }
                    if let url = artifact.fileURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Copy File Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                    }
                    if let code = artifact.inlineContent {
                        Button("Save As…") { save(code, suggested: artifact) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 28) {
                if let conversation {
                    Button { services.show(conversation) } label: {
                        Fact(label: "From") {
                            Text(conversation.title).foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open the conversation")
                }
                if !artifact.container.isEmpty {
                    Fact(label: "In") { Text(artifact.container) }
                }
                Fact(label: "Kind") { Text(kindName(artifact)) }
                Fact(label: "Size") { Text(Int64(artifact.bytes).fileSize) }
                if let date = artifact.createdAt {
                    Fact(label: "Made") { Text(date.listStamp) }
                }
                Spacer(minLength: 0)
            }
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

    private func save(_ code: String, suggested artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.title.replacingOccurrences(of: "/", with: "-")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(code.utf8).write(to: url, options: .atomic)
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
