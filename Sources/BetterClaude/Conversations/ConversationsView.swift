import CoworkKit
import SwiftUI

/// Every conversation on the Mac as one timeline, the open one beside it, and its details.
struct ConversationsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            TimelineColumn()
                .frame(width: 290)
            Rectangle().fill(Theme.Surface.line).frame(width: 0.5)
            ReaderView()
                .frame(maxWidth: .infinity)
            if services.showsInspector {
                Rectangle().fill(Theme.Surface.line).frame(width: 0.5)
                ReaderInspector()
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.Surface.window)
        .animation(Theme.Motion.snappy, value: services.showsInspector)
        .toolbarTitleMenu { FilterMenu() }
        .toolbar {
            if let conversation = services.reader.conversation {
                ToolbarItem(placement: .primaryAction) {
                    Button { services.rewinding = RewindModel(conversation: conversation) } label: {
                        Label("Changes", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon)
                    }
                    .disabled(conversation.external != nil)
                    .help("What this conversation did to files (⇧⌘C)")
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                ToolbarSpacer(.fixed)
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ShareActions(conversation: conversation)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .menuIndicator(.hidden)
                    .help("Export, hand off or replay")
                    Menu {
                        MoreActions(conversation: conversation)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("More for this conversation")
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .primaryAction) {
                    Group {
                        if conversation.external != nil {
                            Button("Write a Handoff…") { services.beginHandoff(conversation) }
                        } else {
                            Button("Continue in…") { services.beginContinue(conversation) }
                                .disabled(conversation.isTranscriptMissing)
                        }
                    }
                    .buttonStyle(PrimaryButton(height: 30))
                    .help("Carry this conversation to another Claude or to Claude Code")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button { services.showsInspector.toggle() } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide details (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            ToolbarItem(placement: .primaryAction) {
                SearchPill(prompt: "Search", width: 150) { services.showsPalette = true }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// Which conversations the timeline shows: all, one install's, or one project's.
struct FilterMenu: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Button("All conversations") { services.filter = .all }
        Section("Sources") {
            ForEach(services.installs.filter { services.conversationCount(in: $0) > 0 }) { install in
                Button(install.name) { services.filter = .install(install.id) }
            }
        }
        let projects = services.projects
        if !projects.isEmpty {
            Section("Projects") {
                ForEach(projects, id: \.path) { project in
                    Button(project.name) { services.filter = .project(project.path) }
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineColumn: View {
    @Environment(AppServices.self) private var services
    @FocusState private var focused: Bool

    var body: some View {
        let conversations = services.visibleConversations
        VStack(alignment: .leading, spacing: 0) {
            if showsMessageHits {
                HStack {
                    Text(countText(services.search.hits.count))
                        .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
                    Spacer()
                    Button("Clear") { services.query = "" }.buttonStyle(.accentLink)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                MessageHitsList()
            } else if conversations.isEmpty {
                emptyTimeline
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(TimelineGroup.group(conversations)) { group in
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.Surface.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.conversations) { conversation in
                                    ConversationRow(conversation: conversation,
                                                    install: services.install(for: conversation),
                                                    live: services.pulse.session(forConversation: conversation.cliSessionId)?.state,
                                                    isSelected: services.selectedConversationID == conversation.id)
                                        .id(conversation.id)
                                        .onTapGesture { services.selectedConversationID = conversation.id; focused = true }
                                        .contextMenu { ConversationActions(conversation: conversation, asContextMenu: true) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1, in: conversations, proxy: proxy) }
                    .onKeyPress(.upArrow) { move(-1, in: conversations, proxy: proxy) }
                }
            }
        }
    }

    private func move(_ step: Int, in conversations: [ConversationRef], proxy: ScrollViewProxy) -> KeyPress.Result {
        let ordered = TimelineGroup.group(conversations).flatMap(\.conversations)
        guard !ordered.isEmpty else { return .ignored }
        let index = ordered.firstIndex { $0.id == services.selectedConversationID } ?? (step > 0 ? -1 : ordered.count)
        let next = ordered[min(max(index + step, 0), ordered.count - 1)]
        services.selectedConversationID = next.id
        proxy.scrollTo(next.id)
        return .handled
    }

    private func countText(_ count: Int) -> String {
        if !services.hasLoaded { return "Looking…" }
        if showsMessageHits { return count == 1 ? "1 conversation matches" : "\(count) conversations match" }
        if !services.query.isEmpty { return count == 1 ? "1 title matches" : "\(count) titles match" }
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    /// Once the index has caught up, a search looks inside every message; until then it
    /// narrows the timeline by title.
    private var showsMessageHits: Bool {
        !services.query.trimmingCharacters(in: .whitespaces).isEmpty && services.index.isReady
    }

    @ViewBuilder
    private var emptyTimeline: some View {
        if !services.hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading your conversations…")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !services.query.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: "No titles match",
                       message: "Search inside messages to look through what was said, not just titles.")
        } else {
            EmptyState(systemImage: "bubble.left.and.bubble.right", title: "No conversations yet",
                       message: "Conversations from Claude, its copies, and Claude Code appear here as soon as they exist.")
        }
    }
}

/// Conversations bucketed the way people remember them.
struct TimelineGroup: Identifiable {
    let title: String
    let conversations: [ConversationRef]
    var id: String { title }

    static func group(_ conversations: [ConversationRef], now: Date = .now) -> [TimelineGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [ConversationRef]] = [:]
        for conversation in conversations {
            let title = bucket(conversation.lastActivity, now: now, calendar: calendar)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(conversation)
        }
        return order.map { TimelineGroup(title: $0, conversations: buckets[$0] ?? []) }
    }

    static func bucket(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return "This week" }
        if days < 30 { return "This month" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

struct ConversationRow: View {
    let conversation: ConversationRef
    let install: Install?
    /// Set while Claude Code is running this conversation.
    var live: LiveSession.State?
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let install { InstallIcon(install: install, size: 22) } else { Color.clear }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Surface.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    switch live {
                    case .needsYou:
                        Text("Needs you").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.attention)
                    case .working:
                        Text("Working").font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
                    default:
                        Text(conversation.lastActivity.listStamp)
                            .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
                    }
                }
                HStack(spacing: 4) {
                    Text(secondLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Surface.secondary)
                        .lineLimit(1)
                    if conversation.isStarred {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.Surface.tertiary)
                            .accessibilityLabel("Starred")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.Surface.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var secondLine: String {
        if conversation.isTranscriptMissing { return "Messages were removed" }
        if let project = conversation.projectName { return project }
        return install?.name ?? ""
    }
}

// MARK: - Message search results

struct MessageHitsList: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let search = services.search
        if search.hits.isEmpty && (search.isSearching || search.lastQuery != services.query.trimmingCharacters(in: .whitespaces)) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.hits.isEmpty {
            EmptyState(systemImage: "text.magnifyingglass", title: "Nothing found",
                       message: "No message in any conversation contains “\(search.lastQuery)”.")
        } else {
            List {
                ForEach(search.hits) { hit in
                    Button {
                        if let conversation = services.snapshot.conversations.first(where: { $0.id == hit.conversationID }) {
                            services.query = ""
                            services.show(conversation)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hit.title).font(Theme.Font.bodyMedium).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(matchText(hit))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ForEach(hit.excerpts.prefix(2)) { excerpt in
                                Text(highlighted(excerpt))
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let conversation = services.snapshot.conversations.first(where: { $0.id == hit.conversationID }) {
                            ConversationActions(conversation: conversation, asContextMenu: true)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func matchText(_ hit: HistorySearch.Hit) -> String {
        switch hit.matchingMessages {
        case 0: return "In the title"
        case 1: return "1 message"
        default: return "\(hit.matchingMessages) messages"
        }
    }

    private func highlighted(_ excerpt: HistorySearch.Excerpt) -> AttributedString {
        var text = AttributedString(excerpt.text)
        for range in excerpt.matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = .primary
            text[lower..<upper].font = Theme.Font.callout.weight(.semibold)
        }
        return text
    }
}
