import AppKit
import CoworkKit
import SwiftUI

/// Every file Claude changed, and where each came from: the conversations, the versions
/// Claude Code saved before each change, and the commits.
struct FilesPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let files = services.files
        HStack(spacing: 0) {
            FileListColumn()
                .frame(width: 320)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                if files.selectedPath != nil {
                    FileDetail()
                } else {
                    EmptyState(systemImage: "doc.text.magnifyingglass", title: "Pick a file",
                               message: "Choose one on the left to see which conversations changed it, and every version Claude saved.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            files.attach(services)
            files.reload()
        }
        .onChange(of: services.index.generation) { _, _ in files.reload() }
    }
}

private struct FileListColumn: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var files = services.files
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Files").font(Theme.Font.title)
                Text(files.files.count == 1 ? "1 file Claude changed" : "\(files.files.count) files Claude changed")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name or folder", text: $files.filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.control))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            List(selection: $files.selectedPath) {
                ForEach(files.files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                .font(Theme.Font.bodyMedium)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let changed = file.lastChanged {
                                Text(changed.listStamp)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Text(folder(of: file.path))
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(.vertical, 3)
                    .tag(file.path)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func folder(of path: String) -> String {
        services.snapshot.paths.abbreviating(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
}

private struct FileDetail: View {
    @Environment(AppServices.self) private var services
    @State private var confirmingRestore: FileHistory.SavedVersion?

    var body: some View {
        let files = services.files
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let path = files.selectedPath { header(path, history: files.history) }
                if let history = files.history {
                    versions(history)
                    touches(history)
                }
                if !files.commits.isEmpty { commits(files.commits) }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Put back this version?", isPresented: Binding(
            get: { confirmingRestore != nil }, set: { if !$0 { confirmingRestore = nil } }),
                            presenting: confirmingRestore) { version in
            Button(version.didNotExist ? "Remove the File" : "Put It Back") { files.restore(version) }
            Button("Cancel", role: .cancel) {}
        } message: { version in
            Text(version.didNotExist
                 ? "The file didn't exist at this point. It will be removed, and a copy of it as it is now is kept so you can undo this from History."
                 : "The file goes back to how it was then. A copy of it as it is now is kept, so you can undo this from History.")
        }
        .alert("Couldn't put it back", isPresented: Binding(
            get: { files.errorMessage != nil }, set: { if !$0 { files.errorMessage = nil } })) {
            Button("OK") { files.errorMessage = nil }
        } message: {
            Text(files.errorMessage ?? "")
        }
    }

    private func header(_ path: String, history: FileHistory?) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            // Not the Finder icon: macOS reads `.ts` as an MPEG video, and most of what
            // Claude changes is text it doesn't know.
            GlyphTile(systemImage: "doc.text", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(Theme.Font.display).lineLimit(1)
                Text(services.snapshot.paths.abbreviating(path))
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let history {
                    Text(summary(history))
                        .font(Theme.Font.callout)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Theme.Space.l)
            MoreMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .disabled(!FileManager.default.fileExists(atPath: path))
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .disabled(!FileManager.default.fileExists(atPath: path))
            }
        }
        .padding(.bottom, Theme.Space.xl)
    }

    private func summary(_ history: FileHistory) -> String {
        let count = history.conversations.count
        let changed = count == 1 ? "Changed in 1 conversation" : "Changed in \(count) conversations"
        if history.createdByClaude, let first = history.versions.first {
            return "Created by Claude in “\(first.conversationTitle)”. \(changed)."
        }
        return changed + "."
    }

    // MARK: Versions

    private func versions(_ history: FileHistory) -> some View {
        let files = services.files
        return DetailSection(title: "Versions",
                             subtitle: "Claude Code saves a file just before changing it. Pick one to see what's changed since.") {
            if history.versions.isEmpty {
                Text("No versions were saved: Claude read this file, or changed it before Claude Code kept versions.")
                    .font(Theme.Font.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(spacing: 0) {
                        ForEach(history.versions.reversed()) { version in
                            VersionRow(version: version, isSelected: files.selectedVersionID == version.id) {
                                files.selectedVersionID = version.id
                            }
                        }
                    }
                    if let restored = files.lastRestore {
                        HStack {
                            Text("Put back. The version from before is kept.")
                                .font(Theme.Font.callout)
                            Spacer()
                            Button("Undo") { files.undoLastRestore() }.buttonStyle(.secondary)
                        }
                        .id(restored.id)
                    }
                    diffView(files)
                }
            }
        }
    }

    @ViewBuilder
    private func diffView(_ files: FilesModel) -> some View {
        if let version = files.selectedVersion {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    if let diff = files.diff {
                        Text(diff.isEmpty ? "No changes since then" : "Since then: \(diff.added) added, \(diff.removed) removed")
                            .font(Theme.Font.headline)
                    } else if let note = files.diffNote {
                        Text(note).font(Theme.Font.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if version.copy != nil || version.didNotExist {
                        Button(version.didNotExist ? "Remove the File…" : "Put This Version Back…") {
                            confirmingRestore = version
                        }
                        .buttonStyle(.secondary)
                        .disabled(files.diff?.isEmpty == true)
                    }
                }
                if let diff = files.diff, !diff.isEmpty { DiffView(diff: diff) }
            }
        }
    }

    // MARK: Conversations and commits

    private func touches(_ history: FileHistory) -> some View {
        DetailSection(title: "Conversations", subtitle: "Every conversation whose tools read or changed this file.") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(history.conversations) { touch in
                    Button { open(touch.conversationID) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(touch.title).font(Theme.Font.body).lineLimit(1)
                                Text(toolsText(touch.tools)).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let last = touch.lastTouched {
                                Text(last.listStamp).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toolsText(_ tools: [String]) -> String {
        let changed = tools.contains { ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains($0) }
        let read = tools.contains { ["Read", "NotebookRead"].contains($0) }
        switch (changed, read) {
        case (true, true): return "Read and changed it"
        case (true, false): return "Changed it"
        default: return "Read it"
        }
    }

    private func commits(_ commits: [CommitLink]) -> some View {
        DetailSection(title: "Commits",
                      subtitle: "Commits that changed this file, and the conversation each most likely came from: the one that edited its files in the hours before.") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(commits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(commit.shortSHA)
                            .font(Theme.Font.code)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.subtleFill, in: .rect(cornerRadius: 5))
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).font(Theme.Font.body).lineLimit(2)
                            if let match = commit.match {
                                Button { open(match.conversationID) } label: {
                                    Text("\(match.confidence == .likely ? "Likely from" : "Possibly from") “\(match.title)”")
                                        .font(Theme.Font.callout)
                                        .foregroundStyle(match.confidence == .likely ? Theme.accent : .secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text("No conversation changed its files just before it")
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(commit.date.listStamp).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func open(_ conversationID: String) {
        if let conversation = services.snapshot.conversations.first(where: { $0.id == conversationID }) {
            services.show(conversation)
        }
    }
}

private struct VersionRow: View {
    let version: FileHistory.SavedVersion
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text("Before a change in “\(version.conversationTitle)”")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(state)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        guard let saved = version.savedAt else { return "Version \(version.version)" }
        return saved.listStamp == saved.formatted(.dateTime.hour().minute())
            ? "Today at \(saved.formatted(.dateTime.hour().minute()))"
            : "\(saved.listStamp) at \(saved.formatted(.dateTime.hour().minute()))"
    }

    private var state: String {
        if version.didNotExist { return version.version == 1 ? "Before Claude created it" : "Didn't exist" }
        return version.copy == nil ? "Copy deleted" : ""
    }
}

/// A diff on its own surface: the one place this app sets text in a monospaced face.
struct DiffView: View {
    let diff: LineDiff
    /// The visible width, so each row's tint reaches the edge even when lines are short.
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines.prefix(400)) { line in
                    HStack(spacing: 8) {
                        Text(line.number.map(String.init) ?? "")
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                        Text(marker(line.kind)).foregroundStyle(color(line.kind))
                        Text(line.kind == .gap ? "…" : line.text)
                            .foregroundStyle(line.kind == .gap ? .secondary : .primary)
                            .fixedSize()
                    }
                    .font(Theme.Font.code)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, 6)
            .frame(minWidth: width, alignment: .leading)
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
        .frame(maxHeight: 420)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
        .textSelection(.enabled)
    }

    private func marker(_ kind: LineDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func color(_ kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return Theme.accent
        case .removed: return Theme.failure
        default: return .secondary
        }
    }

    private func background(_ kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return Theme.accent.opacity(0.14)
        case .removed: return Theme.failure.opacity(0.10)
        default: return .clear
        }
    }
}
