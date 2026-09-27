import AppKit
import CoworkKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MemoryModel {
    private(set) var groups: [MemoryGroup] = []
    private(set) var loaded = false
    private(set) var matches: [MemoryGroup]?
    var query = "" { didSet { filter() } }
    var selectedID: String?

    func load(_ snapshot: CatalogSnapshot) {
        let installs = snapshot.installs
        var known: [URL: String] = [:]
        for conversation in snapshot.conversations {
            if let session = conversation.claudeCodeSession, !session.resolvedCwd.isEmpty {
                known[session.projectDir] = session.resolvedCwd
            }
        }
        let folders = known
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                MemoryInventory.groups(installs: installs, knownFolders: folders)
            }.value
            groups = found
            loaded = true
            if selectedID == nil { selectedID = found.first?.id }
            filter()
        }
    }

    private func filter() {
        let needle = query
        let current = groups
        guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else { matches = nil; return }
        Task {
            let found = await Task.detached { MemoryInventory.search(current, query: needle) }.value
            if query == needle { matches = found }
        }
    }

    var visible: [MemoryGroup] { matches ?? groups }
    var selected: MemoryGroup? { selectedID.flatMap { id in groups.first { $0.id == id } } }
}

struct MemoryPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            MemoryColumn().frame(width: 320)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            MemoryDetail().frame(maxWidth: .infinity)
        }
        .task(id: services.generation) {
            if services.hasLoaded { services.memory.load(services.snapshot) }
        }
    }
}

private struct MemoryColumn: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var memory = services.memory
        let groups = memory.visible
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory").font(Theme.Font.title)
                    Text("What Claude is told to remember, everywhere it keeps it.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                FindField(text: $memory.query, prompt: "Search memory")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !memory.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                EmptyState(systemImage: "brain", title: memory.query.isEmpty ? "No memory yet" : "Nothing found",
                           message: memory.query.isEmpty
                               ? "When Claude saves memory or a project has a CLAUDE.md, it shows up here."
                               : "No memory file mentions “\(memory.query)”.")
            } else {
                List(selection: $memory.selectedID) {
                    section("Everywhere", groups.filter { $0.kind == .everywhere })
                    section("Claude Code projects", groups.filter { $0.kind == .project })
                    section("Cowork projects", groups.filter { $0.kind == .coworkProject })
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ groups: [MemoryGroup]) -> some View {
        if !groups.isEmpty {
            Text(title)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            ForEach(groups) { group in
                HStack(spacing: 10) {
                    Image(systemName: group.kind == .coworkProject ? "folder.badge.person.crop"
                          : group.kind == .everywhere ? "globe" : "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title).font(Theme.Font.bodyMedium).lineLimit(1)
                        Text(group.isOrphaned ? "Its folder is gone"
                             : group.kind == .everywhere ? "Claude Code reads this in every folder"
                             : group.files.count == 1 ? "1 file" : "\(group.files.count) files")
                            .font(Theme.Font.caption)
                            .foregroundStyle(group.isOrphaned ? Theme.attention : .secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(group.id)
                .listRowSeparator(.hidden)
            }
        }
    }
}

private struct MemoryDetail: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if let group = services.memory.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(Theme.Font.display)
                        if let folder = group.folder {
                            Text(services.snapshot.paths.abbreviating(folder))
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if group.isOrphaned {
                        InstallNotice(symbol: "folder.badge.questionmark",
                                      title: "The folder this memory is about is gone",
                                      detail: "It was moved or deleted. Claude only reads this memory when it works in that folder, so it won't be used again unless the folder comes back.",
                                      action: ("Show in Finder", {
                                          if let first = group.files.first {
                                              NSWorkspace.shared.activateFileViewerSelecting([first.url])
                                          }
                                      }))
                    }
                    ForEach(group.files) { file in
                        MemoryFileView(file: file)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 48)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(group.id)
        } else {
            EmptyState(systemImage: "brain", title: "Pick a project",
                       message: "Choose one on the left to read what Claude remembers about it.")
        }
    }
}

private struct MemoryFileView: View {
    let file: MemoryFile
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.name).font(Theme.Font.headline)
                if let modified = file.modified {
                    Text(modified.listStamp).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Editor") { NSWorkspace.shared.open(file.url) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.accent)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if let text {
                    MarkdownView(Self.withoutFrontMatter(text))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.subtleFill.opacity(0.6), in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
        .task(id: file.url) {
            text = await Task.detached {
                guard let handle = try? FileHandle(forReadingFrom: file.url) else { return "" }
                defer { try? handle.close() }
                return String(decoding: (try? handle.read(upToCount: 200_000)) ?? Data(), as: UTF8.self)
            }.value
        }
    }

    /// The `---` block at the top of a memory file is bookkeeping, not what it says.
    static func withoutFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...])
    }
}
