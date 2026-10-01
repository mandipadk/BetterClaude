import AppKit
import CoworkKit
import SwiftUI

/// Every project folder, and everything about one: conversations from every Claude and
/// account, pull requests, the files Claude changed, what it cost, and its memory.
@MainActor
@Observable
final class ProjectsModel {
    private(set) var projects: [ProjectSummary] = []
    private(set) var loaded = false
    private(set) var detail: ProjectDetail?
    /// Corrections made in more than one of the selected project's conversations.
    private(set) var corrections: [CorrectionSuggestion] = []
    /// The wording to add, as edited, by suggestion.
    var wording: [String: String] = [:]
    var chosen: Set<String> = []
    private(set) var added: Int?
    private(set) var decisions: [Decision] = []
    var selectedID: String? {
        didSet { if selectedID != oldValue { loadDetail() } }
    }
    private var index: HistoryIndex?

    func load(index: HistoryIndex?) {
        guard let index else { return }
        self.index = index
        Task {
            projects = (try? await Projects.list(index: index)) ?? []
            loaded = true
            if let selectedID, !projects.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            } else {
                loadDetail()
            }
        }
    }

    func dismiss(_ decision: Decision) {
        try? DismissedDecisions.dismiss(decision.id)
        decisions.removeAll { $0.id == decision.id }
    }

    func rule(_ suggestion: CorrectionSuggestion) -> String { wording[suggestion.id] ?? suggestion.rule }

    func addChosen() {
        guard let project = detail?.summary.path else { return }
        let rules = corrections.filter { chosen.contains($0.id) }.map(rule)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !rules.isEmpty else { return }
        do {
            try Corrections.add(rules, to: Corrections.target(for: project))
            added = rules.count
            corrections.removeAll { chosen.contains($0.id) }
            chosen = []
            loadDetail()
        } catch {
            added = nil
        }
    }

    private func loadDetail() {
        guard let index, let summary = projects.first(where: { $0.id == selectedID }) else { detail = nil; return }
        Task {
            let found = try? await Projects.detail(of: summary, index: index)
            if found?.summary.id == selectedID { detail = found }
            let all = (try? await Corrections.suggestions(index: index)) ?? []
            let decided = (try? await Decisions.list(index: index, project: summary.path)) ?? []
            guard summary.id == selectedID else { return }
            decisions = decided
            corrections = all.filter { $0.project == summary.path }
            chosen = Set(corrections.map(\.id))
            added = nil
        }
    }
}

struct ProjectsPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let model = services.projectPages
        Group {
            if model.selectedID != nil, let detail = model.detail {
                ProjectDetailView(detail: detail)
            } else if model.selectedID != nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Surface.window)
            } else {
                list
            }
        }
        .task(id: services.index.generation) { model.load(index: services.index.index) }
    }

    private var list: some View {
        let model = services.projectPages
        return PageScroll(maxWidth: 820) {
            PageTitle(title: "Projects",
                      subtitle: model.loaded ? "\(model.projects.count) folder\(model.projects.count == 1 ? "" : "s") Claude has worked in, newest first." : "Reading…")
            SectionLabel(title: "Every project", top: 22)
            Card(inset: 44) {
                Button { services.destination = .memory } label: {
                    Row(title: "Everywhere", detail: "The CLAUDE.md and memory every session reads") {
                        RowSymbol(name: "globe")
                    } trailing: { Chevron() }
                }
                .buttonStyle(.plain)
                Button { services.destination = .files } label: {
                    Row(title: "Files Claude changed", detail: "Every file, with its versions and the conversations behind them") {
                        RowSymbol(name: "doc.text")
                    } trailing: { Chevron() }
                }
                .buttonStyle(.plain)
            }
            SectionLabel(title: "Folders")
            Card(inset: 44) {
                ForEach(model.projects) { project in
                    Button { services.openProject(project.id) } label: {
                        Row(title: project.name, detail: line(project)) {
                            RowSymbol(name: "folder")
                        } trailing: {
                            if project.cost > 0 { RowValue(text: UsagePage.dollars(project.cost)) }
                            Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { services.openProject(project.id) }
                        Button("Show Conversations") {
                            services.filter = .project(project.path)
                            services.destination = .conversations
                        }
                        Button("New Session in Claude Code") { services.newSession(in: project.path) }
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                        }
                    }
                }
            }
            if !services.coworkProjects.isEmpty {
                SectionLabel(title: "Cowork projects")
                Card(inset: 44) {
                    ForEach(services.coworkProjects) { project in
                        Row(title: project.name, detail: coworkLine(project)) {
                            RowSymbol(name: "rectangle.stack")
                        } trailing: {
                            Button("Copy to…") { services.beginProjectCopy(project) }
                                .buttonStyle(.secondary)
                                .help("Copy this project and its conversations into another Claude")
                        }
                        .contextMenu {
                            Button("Copy to Another Claude…") { services.beginProjectCopy(project) }
                            if let folder = project.space.folders.first {
                                Divider()
                                Button("Show Folder in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: services.generation) { services.loadCoworkProjects() }
    }

    private func coworkLine(_ project: CoworkProject) -> String {
        let install = services.installs.first { install in
            (services.snapshot.accounts[install.id] ?? []).contains { $0.id == project.account.id }
        }
        let count = "\(project.sessions.count) conversation\(project.sessions.count == 1 ? "" : "s")"
        return install.map { "\(count) in \($0.name)" } ?? count
    }

    private func line(_ project: ProjectSummary) -> String {
        var text = "\(project.conversations) conversation\(project.conversations == 1 ? "" : "s")"
        if let last = project.lastActivity { text += ", last \(last.listStamp.lowercasedIfWordLocal)" }
        return text
    }
}

enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, conversations, files, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .conversations: return "Conversations"
        case .files: return "Files"
        case .memory: return "Memory"
        }
    }
}

private struct ProjectDetailView: View {
    @Environment(AppServices.self) private var services
    let detail: ProjectDetail
    @AppStorage("projectTab") private var tab: ProjectTab = .overview
    @State private var health: MemoryHealth?

    var body: some View {
        let summary = detail.summary
        PageScroll {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.Surface.secondary)
                    .frame(width: 48, height: 48)
                    .background(Theme.Surface.group, in: .rect(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.Surface.line, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.Surface.primary)
                    Text(facts(summary)).font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary).lineLimit(2)
                }
            }
            Segmented(options: ProjectTab.allCases.map { ($0, $0.title) }, selection: $tab)
                .padding(.top, 22)
            switch tab {
            case .overview: overview(summary)
            case .conversations: conversations(summary)
            case .files: files
            case .memory: memory
            }
        }
        .id(detail.summary.id)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Show Conversations") {
                        services.filter = .project(summary.path)
                        services.destination = .conversations
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.path, forType: .string)
                    }
                } label: { Label("More", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Session in Claude Code") { services.newSession(in: summary.path) }
                    .buttonStyle(PrimaryButton(height: 30))
                    .disabled(!FileManager.default.fileExists(atPath: summary.path))
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .task(id: summary.id) {
            let folder = detail.memory.first { $0.lastPathComponent == "memory" }
            health = folder.flatMap(MemoryHealth.check)
        }
    }

    private func facts(_ summary: ProjectSummary) -> String {
        var line = services.snapshot.paths.abbreviating(summary.path) + ". "
        line += summary.conversations == 1 ? "1 conversation" : "\(summary.conversations) conversations"
        if !summary.places.isEmpty { line += " in " + ListFormatter.localizedString(byJoining: Array(summary.places.prefix(2))) }
        if let last = summary.lastActivity { line += ", last active \(last.listStamp.lowercasedIfWordLocal)" }
        return line + "."
    }

    @ViewBuilder
    private func overview(_ summary: ProjectSummary) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                CorrectionsSection(project: summary.path)
                SectionLabel(title: "Memory")
                Card(inset: 44) {
                    let claudeMD = detail.memory.first { $0.lastPathComponent == "CLAUDE.md" }
                    if let claudeMD {
                        Button { NSWorkspace.shared.open(claudeMD) } label: {
                            Row(title: "CLAUDE.md", detail: lineCount(claudeMD)) { RowSymbol(name: "doc.text") } trailing: { Chevron() }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Row(title: "CLAUDE.md", detail: "None yet. What you add from here goes in one.") { RowSymbol(name: "doc.text") } trailing: { EmptyView() }
                    }
                    if let health {
                        Row(title: "Memory notes",
                            detail: health.unlinked.isEmpty ? "Every note is linked from MEMORY.md"
                                : "\(health.unlinked.count) that Claude never sees",
                            detailColor: health.unlinked.isEmpty ? Theme.Surface.secondary : Theme.attention) {
                            RowSymbol(name: "brain")
                        } trailing: {
                            if !health.unlinked.isEmpty {
                                Button(health.unlinked.count == 1 ? "Link It" : "Link Them") {
                                    _ = try? health.link(health.unlinked)
                                    self.health = MemoryHealth.check(folder: health.index.deletingLastPathComponent())
                                }
                                .buttonStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(title: "Decided")
                Card {
                    if services.projectPages.decisions.isEmpty {
                        Row(title: "Nothing settled yet", detail: "Decisions made in this project's conversations show up here.")
                    }
                    ForEach(services.projectPages.decisions.prefix(8)) { decision in
                        Button {
                            if let conversation = services.snapshot.conversations.first(where: { $0.id == decision.conversationID }) {
                                services.show(conversation)
                            }
                        } label: {
                            Row(title: decision.text,
                                detail: [decision.conversationTitle, decision.date?.listStamp.lowercasedIfWordLocal].compactMap { $0 }.joined(separator: ", ")) {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Not a Decision") { services.projectPages.dismiss(decision) } }
                    }
                }
                if !detail.pullRequests.isEmpty {
                    SectionLabel(title: "Pull requests")
                    Card {
                        ForEach(detail.pullRequests) { pull in
                            Button { if let url = URL(string: pull.url) { NSWorkspace.shared.open(url) } } label: {
                                Row(title: pull.name, detail: "From \(pull.conversationTitle)") { Chevron() }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func lineCount(_ url: URL) -> String {
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        let edited = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(lines) lines" + (edited.map { ", edited \($0.listStamp.lowercasedIfWordLocal)" } ?? "")
    }

    @ViewBuilder
    private func conversations(_ summary: ProjectSummary) -> some View {
        SectionLabel(title: detail.conversations.count == 1 ? "1 conversation" : "\(detail.conversations.count) conversations",
                     link: "Show in Conversations", action: {
            services.filter = .project(summary.path)
            services.destination = .conversations
        })
        Card {
            ForEach(detail.conversations) { conversation in
                Button {
                    services.filter = .project(summary.path)
                    services.destination = .conversations
                    services.selectedConversationID = conversation.id
                } label: {
                    Row(title: conversation.title,
                        detail: conversation.branch.map { "\(conversation.place), on \($0)" } ?? conversation.place) {
                        if conversation.cost > 0 { RowValue(text: dollars(conversation.cost)) }
                        RowValue(text: conversation.lastActivity?.listStamp ?? "")
                        Chevron()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        if detail.files.isEmpty {
            Text("Claude Code hasn't kept versions of any file it changed here.")
                .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary).padding(.top, 24)
        } else {
            SectionLabel(title: "Files Claude changed")
            Card {
                ForEach(detail.files) { file in
                    Button { services.showFile(file.path) } label: {
                        Row(title: relative(file.path),
                            detail: file.conversations == 1 ? "1 conversation" : "\(file.conversations) conversations") { Chevron() }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FileActions(path: file.path) }
                }
            }
        }
    }

    @ViewBuilder
    private var memory: some View {
        if detail.memory.isEmpty {
            Text("Claude isn't told anything about this project yet: it has no CLAUDE.md or memory.")
                .font(.system(size: 13)).foregroundStyle(Theme.Surface.secondary).padding(.top, 24)
        } else {
            SectionLabel(title: "What Claude is told about this project", link: "All Memory", action: { services.destination = .memory })
            Card {
                ForEach(detail.memory, id: \.self) { url in
                    Row(title: url.lastPathComponent == "memory" ? "Claude Code's memory for this project" : relative(url.path)) {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.secondary)
                    }
                    .contextMenu { FileActions(path: url.path) }
                }
            }
        }
    }

    private func relative(_ path: String) -> String {
        let root = detail.summary.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : services.snapshot.paths.abbreviating(path)
    }

    private func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

/// Things you keep telling Claude in this project, offered as lines for its CLAUDE.md.
private struct CorrectionsSection: View {
    @Environment(AppServices.self) private var services
    let project: String
    @State private var confirming = false
    @State private var editing: String?

    var body: some View {
        let model = services.projectPages
        if !model.corrections.isEmpty || model.added != nil {
            SectionLabel(title: "You keep telling Claude")
            Card {
                if let added = model.added {
                    Row(title: "Added \(added) line\(added == 1 ? "" : "s") to CLAUDE.md", detail: "Undo it from History.")
                }
                ForEach(model.corrections) { suggestion in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { model.chosen.contains(suggestion.id) },
                            set: { on in if on { model.chosen.insert(suggestion.id) } else { model.chosen.remove(suggestion.id) } }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            if editing == suggestion.id {
                                TextField("Line for CLAUDE.md", text: Binding(
                                    get: { model.rule(suggestion) }, set: { model.wording[suggestion.id] = $0 }))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .medium))
                                    .onSubmit { editing = nil }
                            } else {
                                Text(model.rule(suggestion)).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.Surface.primary).lineLimit(2)
                                    .onTapGesture(count: 2) { editing = suggestion.id }
                            }
                            Text("\(suggestion.conversations) conversations")
                                .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
                                .help(said(suggestion))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contextMenu { Button("Edit Wording") { editing = suggestion.id } }
                }
                if !model.corrections.isEmpty {
                    HStack {
                        Spacer()
                        Button("Add \(model.chosen.count) to CLAUDE.md…") { confirming = true }
                            .buttonStyle(.primary)
                            .disabled(model.chosen.isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .confirmationDialog("Add \(model.chosen.count) line\(model.chosen.count == 1 ? "" : "s") to this project's CLAUDE.md?",
                                isPresented: $confirming) {
                Button("Add") { model.addChosen() }
            } message: {
                Text("They go under their own heading in \(services.snapshot.paths.abbreviating(Corrections.target(for: project).path)). What's there now is kept, and Undo in History takes them out.")
            }
        }
    }

    private func said(_ suggestion: CorrectionSuggestion) -> String {
        let first = suggestion.examples.first.map { "You said “\($0.text)”" } ?? ""
        let more = suggestion.examples.count - 1
        return more > 0 ? "\(first), and \(more) more time\(more == 1 ? "" : "s") in \(suggestion.conversations) conversations." : first
    }
}

private struct DecisionRow: View {
    @Environment(AppServices.self) private var services
    let decision: Decision
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.text).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
                Button {
                    services.filter = .all
                    services.destination = .conversations
                    services.selectedConversationID = decision.conversationID
                } label: {
                    Text("\(Text("\(who), in ").foregroundStyle(.secondary))\(Text(decision.conversationTitle).foregroundStyle(Theme.accent))\(Text(decision.date.map { ", \($0.listStamp.lowercasedIfWordLocal)" } ?? "").foregroundStyle(.secondary))")
                        .font(Theme.Font.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button("Not a Decision") { services.projectPages.dismiss(decision) }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }

    private var who: String {
        switch decision.source {
        case .you: return "You said it"
        case .summary: return "Claude's summary"
        case .claude: return "Claude noted it"
        }
    }
}
