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
            if selectedID == nil || !projects.contains(where: { $0.id == selectedID }) {
                selectedID = projects.first?.id
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
        @Bindable var model = services.projectPages
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects").font(Theme.Font.title)
                    Text(model.loaded ? "\(model.projects.count) folders Claude has worked in" : "Reading…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button("Files Claude Changed") { services.destination = .files }
                        Button("Memory") { services.destination = .memory }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                List(selection: $model.selectedID) {
                    ForEach(model.projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name).font(Theme.Font.body).lineLimit(1)
                            Text(line(project))
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .tag(project.id)
                        .contextMenu {
                            Button("Show Conversations") {
                                services.filter = .project(project.path)
                                services.destination = .conversations
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(project.path, forType: .string)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 300)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                if let detail = model.detail {
                    ProjectDetailView(detail: detail)
                } else {
                    EmptyState(systemImage: "folder", title: model.loaded ? "No projects yet" : "Reading…",
                               message: "Folders Claude Code and the Code tab worked in show up here, with everything about each.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: services.index.generation) { model.load(index: services.index.index) }
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

    var body: some View {
        let summary = detail.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Image(systemName: "folder")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .groupSurface(cornerRadius: 11)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).font(Theme.Font.display)
                        Text(facts(summary))
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)])
                    }
                    .buttonStyle(.bordered)
                    .disabled(!FileManager.default.fileExists(atPath: summary.path))
                }
                Picker("Show", selection: $tab) {
                    ForEach(ProjectTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, Theme.Space.l)

                switch tab {
                case .overview: overview(summary)
                case .conversations: conversations(summary)
                case .files: files
                case .memory: memory
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Each project opens at its top.
        .id(detail.summary.id)
    }

    private func facts(_ summary: ProjectSummary) -> String {
        var line = services.snapshot.paths.abbreviating(summary.path) + ". "
        line += summary.conversations == 1 ? "1 conversation" : "\(summary.conversations) conversations"
        if !summary.places.isEmpty { line += " in " + ListFormatter.localizedString(byJoining: Array(summary.places.prefix(2))) }
        if summary.cost > 0 { line += ", \(dollars(summary.cost)) at list prices" }
        if let last = summary.lastActivity { line += ", last active \(last.listStamp.lowercasedIfWordLocal)" }
        return line + "."
    }

    @ViewBuilder
    private func overview(_ summary: ProjectSummary) -> some View {
        if detail.activity.contains(where: { $0.conversations > 0 }) {
            GroupLabel(title: "Activity")
            ActivityGrid(days: detail.activity)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupSurface()
        }
        CorrectionsSection(project: summary.path)
        if !services.projectPages.decisions.isEmpty {
            DetailSection(title: "Decided", subtitle: "What was settled in this project's conversations, newest first.") {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(services.projectPages.decisions.prefix(12)) { decision in
                        DecisionRow(decision: decision)
                    }
                }
            }
        }
        if !detail.pullRequests.isEmpty {
            GroupLabel(title: "Pull requests")
            RowGroup {
                ForEach(detail.pullRequests) { pull in
                    GroupRow(title: pull.name, detail: "From \(pull.conversationTitle)") {
                        if let url = URL(string: pull.url) {
                            Link("Open", destination: url).font(Theme.Font.callout)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func conversations(_ summary: ProjectSummary) -> some View {
        GroupLabel(title: detail.conversations.count == 1 ? "1 conversation" : "\(detail.conversations.count) conversations",
                   link: "Show in Conversations", action: {
            services.filter = .project(summary.path)
            services.destination = .conversations
        })
        RowGroup {
            ForEach(detail.conversations) { conversation in
                Button {
                    services.filter = .project(summary.path)
                    services.destination = .conversations
                    services.selectedConversationID = conversation.id
                } label: {
                    GroupRow(title: conversation.title,
                             detail: conversation.branch.map { "\(conversation.place), on \($0)" } ?? conversation.place) {
                        if conversation.cost > 0 {
                            Text(dollars(conversation.cost)).font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(conversation.lastActivity?.listStamp ?? "")
                            .font(Theme.Font.callout).foregroundStyle(.secondary)
                        RowChevron()
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
                .font(Theme.Font.body).foregroundStyle(.secondary).padding(.top, Theme.Space.xl)
        } else {
            GroupLabel(title: "Files Claude changed")
            RowGroup {
                ForEach(detail.files) { file in
                    Button { services.showFile(file.path) } label: {
                        GroupRow(title: relative(file.path),
                                 detail: file.conversations == 1 ? "1 conversation" : "\(file.conversations) conversations") {
                            RowChevron()
                        }
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
                .font(Theme.Font.body).foregroundStyle(.secondary).padding(.top, Theme.Space.xl)
        } else {
            GroupLabel(title: "What Claude is told about this project", link: "Memory", action: {
                services.destination = .memory
            })
            RowGroup {
                ForEach(detail.memory, id: \.self) { url in
                    GroupRow(title: url.lastPathComponent == "memory" ? "Claude Code's memory for this project" : relative(url.path)) {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered)
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

/// Eight weeks of days, a column per week, shaded by how many conversations were active.
struct ActivityGrid: View {
    let days: [(day: Date, conversations: Int)]

    var body: some View {
        let peak = max(1, days.map(\.conversations).max() ?? 1)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        HStack(alignment: .top, spacing: 4) {
            ForEach(columns.indices, id: \.self) { column in
                VStack(spacing: 4) {
                    ForEach(columns[column], id: \.day) { day in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.conversations == 0 ? Theme.subtleFill
                                  : Theme.accent.opacity(0.25 + 0.75 * Double(day.conversations) / Double(peak)))
                            .frame(width: 14, height: 14)
                            .help("\(day.day.formatted(date: .abbreviated, time: .omitted)): \(day.conversations) conversation\(day.conversations == 1 ? "" : "s")")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days.filter { $0.conversations > 0 }.count) active days in the last eight weeks")
    }
}

/// Things you keep telling Claude in this project, offered as lines for its CLAUDE.md.
private struct CorrectionsSection: View {
    @Environment(AppServices.self) private var services
    let project: String
    @State private var confirming = false

    var body: some View {
        let model = services.projectPages
        if !model.corrections.isEmpty || model.added != nil {
            DetailSection(title: "What you keep correcting",
                          subtitle: "Things you've told Claude in more than one conversation here. In CLAUDE.md, the next session starts knowing them.") {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let added = model.added {
                        Text("Added \(added) line\(added == 1 ? "" : "s") to CLAUDE.md. Undo it from History.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.corrections) { suggestion in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.chosen.contains(suggestion.id) },
                                set: { on in if on { model.chosen.insert(suggestion.id) } else { model.chosen.remove(suggestion.id) } }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Line for CLAUDE.md", text: Binding(
                                    get: { model.rule(suggestion) },
                                    set: { model.wording[suggestion.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.Font.body)
                                Text(said(suggestion))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if !model.corrections.isEmpty {
                        HStack {
                            Spacer()
                            Button("Add \(model.chosen.count) to CLAUDE.md…") { confirming = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.chosen.isEmpty)
                        }
                    }
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
