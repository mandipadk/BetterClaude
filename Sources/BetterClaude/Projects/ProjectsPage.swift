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

private struct ProjectDetailView: View {
    @Environment(AppServices.self) private var services
    let detail: ProjectDetail

    var body: some View {
        let summary = detail.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    GlyphTile(systemImage: "folder", size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).font(Theme.Font.display)
                        Text(services.snapshot.paths.abbreviating(summary.path))
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)])
                    }
                    .buttonStyle(.bordered)
                    .disabled(!FileManager.default.fileExists(atPath: summary.path))
                }
                .padding(.bottom, Theme.Space.l)

                HStack(alignment: .top, spacing: 28) {
                    Fact(label: "Conversations") { Text("\(summary.conversations)") }
                    Fact(label: "At list prices") { Text(dollars(summary.cost)) }
                    if let first = summary.firstActivity { Fact(label: "Since") { Text(first.formatted(date: .abbreviated, time: .omitted)) } }
                    if let last = summary.lastActivity { Fact(label: "Last active") { Text(last.listStamp) } }
                    Fact(label: "In") { Text(summary.places.prefix(2).joined(separator: ", ")) }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, Theme.Space.xl)

                if detail.activity.contains(where: { $0.conversations > 0 }) {
                    DetailSection(title: "Activity", subtitle: "Conversations you worked in each day, the last eight weeks.") {
                        ActivityGrid(days: detail.activity)
                    }
                }

                CorrectionsSection(project: summary.path)

                if !services.projectPages.decisions.isEmpty {
                    DetailSection(title: "Decisions", subtitle: "What was settled in this project's conversations, newest first. Claude can check these too, before deciding again.") {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            ForEach(services.projectPages.decisions.prefix(12)) { decision in
                                DecisionRow(decision: decision)
                            }
                        }
                    }
                }

                DetailSection(title: "Conversations") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(detail.conversations.prefix(40)) { conversation in
                            Button {
                                services.filter = .all
                                services.destination = .conversations
                                services.selectedConversationID = conversation.id
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conversation.title).font(Theme.Font.body).lineLimit(1)
                                        Text(conversation.branch.map { "\(conversation.place), on \($0)" } ?? conversation.place)
                                            .font(Theme.Font.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if conversation.cost > 0 {
                                        Text(dollars(conversation.cost)).font(Theme.Font.callout).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    Text(conversation.lastActivity?.listStamp ?? "")
                                        .font(Theme.Font.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 90, alignment: .trailing)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !detail.pullRequests.isEmpty {
                    DetailSection(title: "Pull requests") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.pullRequests) { pull in
                                HStack(alignment: .firstTextBaseline) {
                                    if let url = URL(string: pull.url) {
                                        Link(pull.name, destination: url).foregroundStyle(Theme.accent)
                                    }
                                    Text("from \(pull.conversationTitle)")
                                        .font(Theme.Font.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                if !detail.files.isEmpty {
                    DetailSection(title: "Files Claude changed", subtitle: "Most recent first. Each opens in Files, with its versions and the conversations that changed it.") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(detail.files.prefix(25)) { file in
                                Button { services.showFile(file.path) } label: {
                                    HStack {
                                        Text(relative(file.path)).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(file.conversations == 1 ? "1 conversation" : "\(file.conversations) conversations")
                                            .font(Theme.Font.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !detail.memory.isEmpty {
                    DetailSection(title: "Memory", subtitle: "What Claude is told about this project.") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.memory, id: \.self) { url in
                                HStack {
                                    Text(url.lastPathComponent == "memory" ? "Claude Code's memory for this project" : relative(url.path))
                                        .font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Each project opens at its top.
        .id(detail.summary.id)
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
