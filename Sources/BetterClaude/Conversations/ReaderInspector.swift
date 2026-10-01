import CoworkKit
import SwiftUI

/// The inspector's tabs, as symbols with their names in help, so five fit side by side.
enum InspectorTab: String, CaseIterable, Identifiable {
    case info, activity, cost, changes, checks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Info"
        case .activity: return "Activity"
        case .cost: return "Cost"
        case .changes: return "Changes"
        case .checks: return "Checks"
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .activity: return "waveform.path.ecg"
        case .cost: return "chart.bar.xaxis"
        case .changes: return "clock.arrow.circlepath"
        case .checks: return "checkmark"
        }
    }
}

/// Everything about the open conversation that isn't the conversation: its facts, who worked
/// when, what it cost, what it changed, and what didn't check out. Hidden with ⌥⌘I.
struct ReaderInspector: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: InspectorTab.allCases.map { ($0, $0.symbol) }, selection: $services.inspectorTab,
                      symbols: true, fill: true)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            if let conversation = services.reader.conversation, services.reader.state == .ready {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(services.inspectorTab.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Surface.primary)
                            .padding(.top, 16)
                        content(conversation)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id("\(conversation.id)#\(services.inspectorTab.rawValue)")
            } else {
                Text("Pick a conversation to see its details.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.Surface.secondary)
                    .padding(16)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.bar)
    }

    @ViewBuilder
    private func content(_ conversation: ConversationRef) -> some View {
        let external = conversation.external != nil
        switch services.inspectorTab {
        case .info:
            ConversationFacts(conversation: conversation, install: services.reader.install, readable: services.reader.readable)
            if !external {
                InspectorLanes(conversation: conversation)
                InspectorFiles(conversation: conversation)
            }
        case .activity:
            if external { unavailable("Sub-agents are recorded by Claude Code only.") } else {
                SubagentsView(conversation: conversation, alwaysOpen: true, compact: true)
                    .overlay { if !hasMarker(.activity) { quiet("No sub-agents ran in this conversation.") } }
            }
        case .cost:
            if external { unavailable("Cost is recorded by Claude Code only.") } else {
                FlightRecorderView(conversation: conversation, alwaysOpen: true)
            }
        case .changes:
            if external { unavailable("Changes to files are recorded by Claude Code only.") } else {
                ChangesSummary(conversation: conversation)
            }
        case .checks:
            if external { unavailable("Claims are checked in Claude Code conversations.") } else {
                ModelSwitchesView(conversation: conversation)
                ClaimsView(conversation: conversation, alwaysOpen: true)
            }
        }
    }

    private func hasMarker(_ tab: InspectorTab) -> Bool {
        services.reader.markers.contains { if case .subagents = $0.kind { return true }; return false }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text).font(Theme.Font.callout).foregroundStyle(.secondary)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(Theme.Font.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }
}

/// A conversation's facts, as label and value rows.
struct ConversationFacts: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    let install: Install?
    let readable: ReadableConversation?
    @State private var cost: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let install { KV("Source", install.name) }
            if let project = conversation.projectName { KV("Project", project) }
            if let model = readable?.model ?? conversation.model { KV("Model", humanModelName(model)) }
            if let readable { KV("Messages", "\(readable.messageCount)") }
            if let cost, cost > 0 { KV("Cost", cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
            if let deletion = ReaderHeader.deletionText(conversation, services: services) { KV("Deleted", deletion) }
            if let readable {
                ForEach(readable.pullRequests, id: \.self) { pull in
                    HStack {
                        Text("Pull request").foregroundStyle(Theme.Surface.secondary)
                        Spacer()
                        Link(pull.name.split(separator: "#").last.map { "#\($0)" } ?? pull.name, destination: pull.url)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 12))
                }
                ForEach(ReaderHeader.related(readable, services: services), id: \.conversation.id) { item in
                    HStack {
                        Text(item.label).foregroundStyle(Theme.Surface.secondary)
                        Spacer()
                        Button(item.conversation.title) { services.selectedConversationID = item.conversation.id }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
            }
            if services.kept.entries.contains(where: { $0.sessionId == conversation.cliSessionId }) { KV("Kept", "Yes") }
        }
        .task(id: conversation.id) {
            guard conversation.external == nil, let index = services.index.index else { return }
            cost = (try? await FlightRecord.load(conversationID: conversation.id, index: index))?.totalCost
        }
    }
}

/// A fact in the inspector: its name on the left, the value on the right.
struct KV: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Theme.Surface.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Theme.Surface.primary).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// Who was working when, small: the conversation and each sub-agent as a thin lane.
struct InspectorLanes: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    @State private var lanes: [(label: String, start: Double, length: Double, main: Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Who was working when").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Surface.primary).padding(.top, 10).padding(.bottom, 1)
                ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                    HStack(spacing: 8) {
                        Text(lane.label).font(.system(size: 11.5)).foregroundStyle(Theme.Surface.secondary)
                            .lineLimit(1).frame(width: 76, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.Surface.fill)
                                Capsule().fill(lane.main ? Theme.accentBright : Theme.Surface.tertiary)
                                    .frame(width: max(5, geometry.size.width * lane.length))
                                    .offset(x: geometry.size.width * lane.start)
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        }
            .task(id: conversation.id) {
                guard let index = services.index.index else { return }
                let runs = ((try? await Subagents.runs(conversationID: conversation.id, index: index)) ?? [])
                    .filter { $0.started != nil }
                guard !runs.isEmpty else { lanes = []; return }
                let replies = (try? await FlightRecord.load(conversationID: conversation.id, index: index))?.replies.map(\.timestamp) ?? []
                let starts = runs.compactMap(\.started) + replies
                let ends = runs.map { $0.ended ?? $0.started! } + replies
                guard let first = starts.min(), let last = ends.max() else { return }
                let span = max(60, last.timeIntervalSince(first))
                var made: [(String, Double, Double, Bool)] = []
                if let a = replies.min(), let b = replies.max() {
                    made.append(("Claude", a.timeIntervalSince(first) / span, b.timeIntervalSince(a) / span, true))
                }
                for run in runs.prefix(6) {
                    let start = run.started!
                    let end = run.ended ?? start
                    made.append((run.title, start.timeIntervalSince(first) / span, end.timeIntervalSince(start) / span, false))
                }
                lanes = made
            }
    }
}

/// The files a conversation changed, with how many lines each gained and lost.
struct InspectorFiles: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    @State private var files: [(name: String, path: String, change: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Files changed").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Surface.primary).padding(.top, 10).padding(.bottom, 1)
                ForEach(files.prefix(8), id: \.path) { file in
                    HStack {
                        Text(file.name).foregroundStyle(Theme.Surface.primary).lineLimit(1)
                        Spacer()
                        Text(file.change).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .contentShape(.rect)
                    .onTapGesture { services.rewinding = RewindModel(conversation: conversation) }
                    .help(file.path)
                }
                if files.count > 8 {
                    Button("All \(files.count) files…") { services.rewinding = RewindModel(conversation: conversation) }
                        .buttonStyle(.accentLink)
                }
            }
        }
        }
            .task(id: conversation.id) {
                guard let index = services.index.index,
                      let changes = try? await ConversationRewind.changes(conversationID: conversation.id, index: index) else { files = []; return }
                let list = changes.files
                files = await Task.detached(priority: .utility) {
                    list.map { file in
                        let name = URL(fileURLWithPath: file.path).lastPathComponent
                        if file.created { return (name, file.path, "new") }
                        let diff = ConversationRewind.diff(for: file)
                        return (name, file.path, diff.map { "+\($0.added) −\($0.removed)" } ?? "")
                    }
                }.value
            }
    }
}

/// The files a conversation changed, with the two ways to look closer.
struct ChangesSummary: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    @State private var changes: ConversationChanges?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let changes {
                if changes.files.isEmpty {
                    Text("This conversation didn't change any files Claude Code kept versions of.")
                        .font(Theme.Font.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(changes.files) { file in
                            HStack {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent).font(Theme.Font.callout).lineLimit(1)
                                Spacer()
                                Text(file.created ? "New" : "\(file.versions) \(file.versions == 1 ? "version" : "versions")")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            .help(file.path)
                            .contextMenu { FileActions(path: file.path) }
                        }
                    }
                    HStack(spacing: Theme.Space.s) {
                        Button("Show Changes…") { services.rewinding = RewindModel(conversation: conversation) }
                        Button("Play…") { services.rewinding = RewindModel(conversation: conversation, playing: true) }
                    }
                    .buttonStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: conversation.id) {
            guard let index = services.index.index else { return }
            changes = try? await ConversationRewind.changes(conversationID: conversation.id, index: index)
        }
    }
}
