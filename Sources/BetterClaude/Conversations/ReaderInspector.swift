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
        case .activity: return "arrow.triangle.branch"
        case .cost: return "chart.bar.xaxis"
        case .changes: return "clock.arrow.circlepath"
        case .checks: return "checkmark.circle"
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
            Picker("Show", selection: $services.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.symbol).help(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            if let conversation = services.reader.conversation, services.reader.state == .ready {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Text(services.inspectorTab.title).font(Theme.Font.headline)
                        content(conversation)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id("\(conversation.id)#\(services.inspectorTab.rawValue)")
            } else {
                ContentUnavailableView("No Conversation", systemImage: "sidebar.right",
                                       description: Text("Pick a conversation to see its details."))
            }
        }
    }

    @ViewBuilder
    private func content(_ conversation: ConversationRef) -> some View {
        let external = conversation.external != nil
        switch services.inspectorTab {
        case .info:
            ConversationFacts(conversation: conversation, install: services.reader.install, readable: services.reader.readable)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let install { FactRow(label: "Source", value: install.name, labelWidth: 92) }
            if let project = conversation.projectName { FactRow(label: "Project", value: project, labelWidth: 92) }
            if let model = readable?.model ?? conversation.model {
                FactRow(label: "Model", value: humanModelName(model), labelWidth: 92)
            }
            FactRow(label: "Last active", value: conversation.lastActivity.formatted(date: .abbreviated, time: .shortened), labelWidth: 92)
            if let readable { FactRow(label: "Messages", value: "\(readable.messageCount)", labelWidth: 92) }
            if let deletion = ReaderHeader.deletionText(conversation, services: services) { FactRow(label: "Deleted", value: deletion, labelWidth: 92) }
            if let readable {
                ForEach(readable.pullRequests, id: \.self) { pull in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text("Pull request").font(Theme.Font.callout).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Link(pull.name, destination: pull.url).font(Theme.Font.callout).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                ForEach(ReaderHeader.related(readable, services: services), id: \.conversation.id) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(item.label).font(Theme.Font.callout).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Button(item.conversation.title) { services.selectedConversationID = item.conversation.id }
                            .buttonStyle(.plain).font(Theme.Font.callout).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
            }
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
                        Button("Play…") { services.watching = TimelapseModel(conversation: conversation) }
                    }
                    .buttonStyle(.bordered)
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
